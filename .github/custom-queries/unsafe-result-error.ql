/**
 * @name Unsafe error() access on Result type
 * @description Accessing .error() when the Result might actually be in a success state (e.g., guarded by an OR condition).
 * @kind problem
 * @problem.severity error
 * @id cpp/unsafe-result-error-access
 */

import cpp

from FunctionCall call, LogicalOrExpr orExpr
where
  // 1. We are calling a method named "error"
  call.getTarget().getName() = "error" and
  // 2. The object we are calling it on has "Result" in its class name
  call.getTarget().getDeclaringType().getName().matches("%Result%") and
  // 3. The call happens inside a block that is guarded by a Logical OR (||)
  // which means the condition might have been true because of a success path!
  call.getEnclosingStmt().getParentStmt*() = orExpr.getEnclosingStmt()
select call, "Unsafe access: .error() called inside a block guarded by an || condition. The result might be a success!"
