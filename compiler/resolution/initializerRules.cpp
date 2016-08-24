/*
 * Copyright 2004-2016 Cray Inc.
 * Other additional copyright holders may be indicated within.
 *
 * The entirety of this work is licensed under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 *
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "initializerRules.h"

#include "astutil.h"
#include "expr.h"
#include "resolution.h"
#include "stmt.h"
#include "stringutil.h"
#include "symbol.h"

// Helper file for verifying the rules placed on initializers, and providing
// the extra functionality associated with them.

void temporaryInitializerFixup(CallExpr* call) {
  if (UnresolvedSymExpr* usym = toUnresolvedSymExpr(call->baseExpr)) {
    // Support super.init() calls (for instance) when the super type does not
    // define either an initializer or a constructor.  Also ignores errors from
    // improperly inserted .init() calls (so be sure to check here if something
    // is behaving oddly - Lydia, 08/19/16)
    if (!strcmp(usym->unresolved, "init")) {
      for_actuals(actual, call) {
        if (NamedExpr* named = toNamedExpr(actual)) {
          if (!strcmp(named->name, "meme")) {
            if (SymExpr* sym = toSymExpr(named->actual)) {
              if (AggregateType* ct = toAggregateType(sym->var->type)) {
                if (ct->initializerStyle == DEFINES_NONE_USE_DEFAULT) {
                  // This code should be removed when the compiler generates
                  // initializers as the default method of construction and
                  // initialization for a type (Lydia note, 08/19/16)
                  usym->unresolved = astr("_construct_", ct->symbol->name);
                } else if (ct->initializerStyle == DEFINES_CONSTRUCTOR) {
                  // This code should be removed when initializers are fully
                  // supported and old style constructors are deprecated
                  // (Lydia note, 08/19/16)
                  USR_FATAL(call, "can't make init call on type with old constructor style");
                }
              }
            }
          }
        }
      }
    }
  }
}

static
void reorganizeBody(FnSymbol* fn, BlockStmt* phase1, BlockStmt* phase2,
                    BlockStmt* otherInit);


void handleInitializerRules(FnSymbol* fn) {
  if (!fn->hasFlag(FLAG_CONSTRUCTOR) || strcmp(fn->name, "init")) {
    USR_PRINT(fn, "'%s' is not an initializer", fn->name);
    return;
  }

  BlockStmt* phase1 = fn->body;
  BlockStmt* phase2 = new BlockStmt();
  BlockStmt* otherInit = new BlockStmt();

  reorganizeBody(fn, phase1, phase2, otherInit);

  phase1->insertAtTail(otherInit);
  phase1->insertAtTail(phase2);

  phase1->insertAtTail(phase2->body.tail->remove());
  // Put the return statement back where we found it.  FnSymbol::getReturnSymbol
  // expects the return statement to be at the end of the function.

  resolveBlockStmt(fn->body);
}

// This function traverses the body of the initializer backwards, moving the
// statements it finds into the phase2 block statement until it encounters the
// super/this.init() call or the start of the body, whichever comes first.
// It then moves the super/this.init() call and the statements it relies on
// into the otherInit block statement.
static
void reorganizeBody(FnSymbol* fn, BlockStmt* phase1, BlockStmt* phase2,
                    BlockStmt* otherInit) {
  while (phase1->body.length > 0) {
    // Note - to make the default for an initializer body be phase 1,
    // reverse the traversal order and perform some swaps of which block
    // statement is receiving the code.  Will also need to update the creation
    // of the phase1 block at the callsite, likely.

    if (CallExpr* call = toCallExpr(phase1->body.tail)) {
      if (CallExpr* inner = toCallExpr(call->baseExpr)) {
        if (inner->isNamed("init")) {
          // While going backwards, we found the super/this.init() call
          // Time to stop moving into the phase2 block statement.
          if (NamedExpr* meme = toNamedExpr(inner->get(1))) {
            if (!strcmp(meme->name, "meme")) {
              if (SymExpr* sym = toSymExpr(meme->actual)) {
                if (sym->var == fn->_this) {
                  // Lydia NOTE: relies on the structure of "this.init()" calls
                  // being of the form:
                  // call( call( init meme = this ) ...)
                  otherInit->insertAtHead(call->remove());
                } else {
                  // Lydia NOTE: relies on the structure of "super.init()" calls
                  // being of the form:
                  // def call_tmp
                  // ...
                  // move( call_tmp call(super _mt[195] this))
                  // call( call( init meme = call_tmp ) ...)
                  otherInit->insertAtHead(sym->var->defPoint->remove());
                  otherInit->insertAtTail(call->prev->remove());
                  otherInit->insertAtTail(call->remove());
                }
              }
            }
          }
          if (otherInit->body.length == 0) {
            // Internal error because I expect this to mean a difference in
            // how the compiler has structured the init call.  Something
            // happened that I did not expect, and so the call has not been
            // inserted into the otherInit block statement.
            INT_FATAL(inner, "Unexpected argument to 'init' call");
          }

          break; // Exiting the traversal.

          // Behavior is not yet correct for super/this.init() calls within
          // loops or if statements.  TODO: fix this
        }
      }
    }
    phase2->insertAtHead(phase1->body.tail->remove());
  }
}
