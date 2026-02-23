/**
 * @name Unsafe error() access after OR condition
 * @description Accessing .error() inside a block guarded by an || condition, meaning it might be a success state.
 * @kind problem
 * @problem.severity error
 * @id cpp/unsafe-result-error-access
 */

import cpp

from FunctionCall call, IfStmt ifStmt
where
  // 1. Look for any function/method call named "error"
  call.getTarget().getName() = "error" and

  // 2. Ensure this call happens somewhere inside the "then" branch of an if-statement
  call.getEnclosingStmt().getParentStmt*() = ifStmt.getThen() and

  // 3. Ensure that if-statement's condition contains an || (Logical OR)
  ifStmt.getCondition().getAChild*() instanceof LogicalOrExpr

select call, "Intentional Bug: .error() called inside an || block. It might be a success state!"
