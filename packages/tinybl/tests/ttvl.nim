import std/unittest
import tinybl/tvl

suite "ternary logic":
  test "AND":
    template AND(a, b, c) =
      check (a and b) == c
    AND T,T,T
    AND T,U,U
    AND T,F,F

    AND U,T,U
    AND U,U,U
    AND U,F,F

    AND F,T,F
    AND F,U,F
    AND F,F,F

  test "OR":
    template OR(a, b, c) =
      check (a or b) == c
    OR T,T,T
    OR T,U,T
    OR T,F,T

    OR U,T,T
    OR U,U,U
    OR U,F,U

    OR F,T,T
    OR F,U,U
    OR F,F,F

  test "XOR":
    template XOR(a, b, c) =
      check (a xor b) == c
    XOR T,T,F
    XOR T,U,U
    XOR T,F,T
    
    XOR U,T,U
    XOR U,U,U
    XOR U,F,U

    XOR F,T,T
    XOR F,U,U
    XOR F,F,F

  test "NOT":
    check not(T) == F
    check not(F) == T
    check not(U) == U

  test "known":
    check T.known == T
    check F.known == T
    check U.known == F