# HEADS UP NOT MY CODE!
# Original DFA Table credit is
# Copyright (c) 2008-2010 Bjoern Hoehrmann <bjoern@hoehrmann.de>
# See http://bjoern.hoehrmann.de/utf-8/decoder/dfa/ for details.

const
  UTF8_ACCEPT = 0
  UTF8_REJECT = 12

  utf8d: array[364, uint8] = [
    # The first part of the table maps bytes to character classes that
    # to reduce the size of the transition table and create bitmasks.
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,
    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
    8,8,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
    10,3,3,3,3,3,3,3,3,3,3,3,3,4,3,3,11,6,6,6,5,8,8,8,8,8,8,8,8,8,8,8,
    # The second part is a transition table that maps a combination
    # of a state of the automaton and a character class to a state.
    0,12,24,36,60,96,84,12,12,12,48,72, 
    12,12,12,12,12,12,12,12,12,12,12,12, 
    12, 0,12,12,12,12,12, 0,12, 0,12,12, 
    12,24,12,12,12,12,12,24,12,24,12,12, 
    12,12,12,12,12,12,12,24,12,12,12,12, 
    12,24,12,12,12,12,12,12,12,24,12,12, 
    12,12,12,12,12,12,12,36,12,36,12,12, 
    12,36,12,12,12,12,12,36,12,36,12,12, 
    12,36,12,12,12,12,12,12,12,12,12,12
  ]

func validateUtf8*(s: openArray[char]): bool {.inline.} =
  var state = UTF8_ACCEPT
  
  for c in s:
    let byteClass = utf8d[uint8(c)]
    state = int(utf8d[256 + state + int(byteClass)])
    
    if state == UTF8_REJECT:
      return false
    
  return state == UTF8_ACCEPT