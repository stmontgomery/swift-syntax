//===------------------ OperatorPrecedence+Folding.swift ------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import SwiftSyntax

extension OperatorPrecedence {
  private struct PrecedenceBound {
    let groupName: PrecedenceGroupName?
    let isStrict: Bool
    let syntax: SyntaxProtocol?
  }

  /// Determine whether we should consider an operator in the given group
  /// based on the specified bound.
  private func shouldConsiderOperator(
    fromGroup groupName: PrecedenceGroupName?,
    in bound: PrecedenceBound,
    fromGroupSyntax: SyntaxProtocol?,
    errorHandler: OperatorPrecedenceErrorHandler = { throw $0 }
  ) rethrows -> Bool {
    guard let boundGroupName = bound.groupName else {
      return true
    }

    guard let groupName = groupName else {
      return false
    }

    if groupName == boundGroupName {
      return !bound.isStrict
    }

    return try precedence(
      relating: groupName, to: boundGroupName,
      startSyntax: fromGroupSyntax, endSyntax: bound.syntax,
      errorHandler: errorHandler
    ) != .lowerThan
  }

  /// Look up the precedence group for the given expression syntax.
  private func lookupPrecedence(
    of expr: ExprSyntax,
    errorHandler: OperatorPrecedenceErrorHandler = { throw $0 }
  ) rethrows -> PrecedenceGroupName? {
    // A binary operator.
    if let binaryExpr = expr.as(BinaryOperatorExprSyntax.self) {
      let operatorName = binaryExpr.operatorToken.text
      return try lookupOperatorPrecedenceGroupName(
        operatorName, referencedFrom: binaryExpr.operatorToken,
        errorHandler: errorHandler
      )
    }

    // FIXME: Handle all of the language-defined precedence relationships.
    return nil
  }

  /// Form a binary operation expression for, e.g., a + b.
  private func makeBinaryOperationExpr(
    lhs: ExprSyntax, op: ExprSyntax, rhs: ExprSyntax
  ) -> ExprSyntax {
    ExprSyntax(
      InfixOperatorExprSyntax(
        leftOperand: lhs, operatorOperand: op, rightOperand: rhs)
      )
  }

  /// Determine the associativity between two precedence groups.
  private func associativity(
    firstGroup: PrecedenceGroupName?,
    firstGroupSyntax: SyntaxProtocol?,
    secondGroup: PrecedenceGroupName?,
    secondGroupSyntax: SyntaxProtocol?,
    errorHandler: OperatorPrecedenceErrorHandler = { throw $0 }
  ) rethrows -> Associativity {
    guard let firstGroup = firstGroup, let secondGroup = secondGroup else {
      return .none
    }

    // If we have the same group, query its associativity.
    if firstGroup == secondGroup {
      guard let group = precedenceGraph.lookupGroup(firstGroup) else {
        try errorHandler(
          .missingGroup(firstGroup, referencedFrom: firstGroupSyntax))
        return .none
      }

      return group.associativity
    }

    if try precedence(
      relating: firstGroup, to: secondGroup,
      startSyntax: firstGroupSyntax, endSyntax: secondGroupSyntax,
      errorHandler: errorHandler
    ) == .higherThan {
      return .left
    }

    if try precedence(
      relating: secondGroup, to: firstGroup,
      startSyntax: secondGroupSyntax, endSyntax: firstGroupSyntax,
      errorHandler: errorHandler
    ) == .higherThan {
      return .right
    }

    return .none
  }

  /// "Fold" an expression sequence where the left-hand side has been broken
  /// out and (potentially) folded somewhat, and the "rest" of the sequence is
  /// consumed along the way
  private func fold(
    _ lhs: ExprSyntax, rest: inout Slice<ExprListSyntax>,
    bound: PrecedenceBound,
    errorHandler: OperatorPrecedenceErrorHandler = { throw $0 }
  ) rethrows -> ExprSyntax {
    if rest.isEmpty { return lhs }

    // We mutate the left-hand side in place as we fold the sequence.
    var lhs = lhs

    /// Get the operator, if appropriate to this pass.
    func getNextOperator() throws -> (ExprSyntax, PrecedenceGroupName?)? {
      let op = rest.first!

      // If the operator's precedence is lower than the minimum, stop here.
      let opPrecedence = try lookupPrecedence(
        of: op, errorHandler: errorHandler)
      if try !shouldConsiderOperator(
        fromGroup: opPrecedence, in: bound, fromGroupSyntax: op
      ) {
        return nil
      }

      return (op, opPrecedence)
    }

    // Extract out the first operator.
    guard var (op1, op1Precedence) = try getNextOperator() else {
      return lhs
    }

    // We will definitely be consuming at least one operator.
    // Pull out the prospective RHS and slice off the first two elements.
    rest = rest.dropFirst()
    var rhs = rest.first!
    rest = rest.dropFirst()

    while !rest.isEmpty {
      #if compiler(>=10.0) && false
      // If the operator is a cast operator, the RHS can't extend past the type
      // that's part of the cast production.
      if (isa<ExplicitCastExpr>(op1.op)) {
        LHS = makeBinOp(Ctx, op1.op, LHS, RHS, op1.precedence, S.empty());
        op1 = getNextOperator();
        if (!op1) return LHS;
        RHS = S[1];
        S = S.slice(2);
        continue;
      }
      #endif

      // Pull out the next binary operator.
      let op2 = rest.first!
      let op2Precedence = try lookupPrecedence(
        of: op2, errorHandler: errorHandler)

      // If the second operator's precedence is lower than the
      // precedence bound, break out of the loop.
      if try !shouldConsiderOperator(
        fromGroup: op2Precedence, in: bound, fromGroupSyntax: op1,
        errorHandler: errorHandler
      ) {
        break
      }

      let associativity = try associativity(
        firstGroup: op1Precedence,
        firstGroupSyntax: op1,
        secondGroup: op2Precedence,
        secondGroupSyntax: op2,
        errorHandler: errorHandler
      )

      switch associativity {
      case .left:
        // Apply left-associativity immediately by folding the first two
        // operands.
        lhs = makeBinaryOperationExpr(lhs: lhs, op: op1, rhs: rhs)
        op1 = op2
        op1Precedence = op2Precedence
        rest = rest.dropFirst()
        rhs = rest.first!
        rest = rest.dropFirst()

      case .right where op1Precedence != op2Precedence:
        // If the first operator's precedence is lower than the second
        // operator's precedence, recursively fold all such
        // higher-precedence operators starting from this point, then
        // repeat.
        rhs = try fold(
          rhs, rest: &rest,
          bound: PrecedenceBound(
            groupName: op1Precedence, isStrict: true, syntax: op1
          ),
          errorHandler: errorHandler
        )

      case .right:
        // Apply right-associativity by recursively folding operators
        // starting from this point, then immediately folding the LHS and RHS.
        rhs = try fold(
          rhs, rest: &rest,
          bound: PrecedenceBound(
            groupName: op1Precedence, isStrict: false, syntax: op1
          ),
          errorHandler: errorHandler
        )

        lhs = makeBinaryOperationExpr(lhs: lhs, op: op1, rhs: rhs)

        // If we've drained the entire sequence, we're done.
        if rest.isEmpty {
          return lhs
        }

        // Otherwise, start all over with our new LHS.
        return try fold(
          lhs, rest: &rest, bound: bound, errorHandler: errorHandler
        )

      case .none:
        // If we ended up here, it's because we're either:
        //   - missing precedence groups,
        //   - have unordered precedence groups, or
        //   - have the same precedence group with no associativity.
        if let op1Precedence = op1Precedence,
            let op2Precedence = op2Precedence {
          try errorHandler(
            .incomparableOperators(
              leftOperator: op1, leftPrecedenceGroup: op1Precedence,
              rightOperator: op2, rightPrecedenceGroup: op2Precedence
            )
          )
        }

        // Recover by folding arbitrarily at this operator, then continuing.
        lhs = makeBinaryOperationExpr(lhs: lhs, op: op1, rhs: rhs)
        return try fold(lhs, rest: &rest, bound: bound, errorHandler: errorHandler)
      }
    }

    // Fold LHS and RHS together and declare completion.
    return makeBinaryOperationExpr(lhs: lhs, op: op1, rhs: rhs)
  }

  /// "Fold" an expression sequence into a structured syntax tree.
  public func fold(
    _ sequence: SequenceExprSyntax,
    errorHandler: OperatorPrecedenceErrorHandler = { throw $0 }
  ) rethrows -> ExprSyntax {
    let lhs = sequence.elements.first!
    var rest = sequence.elements.dropFirst()
    return try fold(
      lhs, rest: &rest,
      bound: PrecedenceBound(groupName: nil, isStrict: false, syntax: nil),
      errorHandler: errorHandler
    )
  }
}
