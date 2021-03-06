// Created to verify semantics of records which define initializers and are
// moved
record R {
  var x: int;
  var y: bool;

  proc init() {
    x = 10;
    y = true;
  }
}

proc useIt(): R {
  var localR: R;
  localR.x = 15;
  return localR;
}

proc main() {
  var r = useIt();
  writeln(r);
}
