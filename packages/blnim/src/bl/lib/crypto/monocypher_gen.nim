
{.warning[UnusedImport]: off.}
{.hint[XDeclaredButNotUsed]: off.}
from std / macros import hint, warning, newLit, getSize

from std / os import parentDir

when not declared(ownSizeOf):
  macro ownSizeof(x: typed): untyped =
    newLit(x.getSize)

type
  struct_crypto_aead_ctx_553648571 {.pure, inheritable, bycopy.} = object
    counter*: uint64         ## Generated based on vendor/monocypher/monocypher.h:97:9
    key*: array[32'i64, uint8]
    nonce*: array[8'i64, uint8]
  crypto_aead_ctx_553648574 = struct_crypto_aead_ctx_553648573 ## Generated based on vendor/monocypher/monocypher.h:101:3
  struct_crypto_blake2b_ctx_553648576 {.pure, inheritable, bycopy.} = object
    hash*: array[8'i64, uint64] ## Generated based on vendor/monocypher/monocypher.h:134:9
    input_offset*: array[2'i64, uint64]
    input*: array[16'i64, uint64]
    input_idx*: csize_t
    hash_size*: csize_t
  crypto_blake2b_ctx_553648578 = struct_crypto_blake2b_ctx_553648577 ## Generated based on vendor/monocypher/monocypher.h:142:3
  struct_crypto_argon2_config_553648580 {.pure, inheritable, bycopy.} = object
    algorithm*: uint32       ## Generated based on vendor/monocypher/monocypher.h:158:9
    nb_blocks*: uint32
    nb_passes*: uint32
    nb_lanes*: uint32
  crypto_argon2_config_553648582 = struct_crypto_argon2_config_553648581 ## Generated based on vendor/monocypher/monocypher.h:163:3
  struct_crypto_argon2_inputs_553648584 {.pure, inheritable, bycopy.} = object
    pass*: ptr uint8         ## Generated based on vendor/monocypher/monocypher.h:165:9
    salt*: ptr uint8
    pass_size*: uint32
    salt_size*: uint32
  crypto_argon2_inputs_553648586 = struct_crypto_argon2_inputs_553648585 ## Generated based on vendor/monocypher/monocypher.h:170:3
  struct_crypto_argon2_extras_553648588 {.pure, inheritable, bycopy.} = object
    key*: ptr uint8          ## Generated based on vendor/monocypher/monocypher.h:172:9
    ad*: ptr uint8
    key_size*: uint32
    ad_size*: uint32
  crypto_argon2_extras_553648590 = struct_crypto_argon2_extras_553648589 ## Generated based on vendor/monocypher/monocypher.h:177:3
  struct_crypto_poly1305_ctx_553648592 {.pure, inheritable, bycopy.} = object
    c*: array[16'i64, uint8] ## Generated based on vendor/monocypher/monocypher.h:289:9
    c_idx*: csize_t
    r*: array[4'i64, uint32]
    pad*: array[4'i64, uint32]
    h*: array[5'i64, uint32]
  crypto_poly1305_ctx_553648594 = struct_crypto_poly1305_ctx_553648593 ## Generated based on vendor/monocypher/monocypher.h:297:3
  struct_crypto_aead_ctx_553648573 = (when declared(struct_crypto_aead_ctx):
    when ownSizeof(struct_crypto_aead_ctx) != ownSizeof(struct_crypto_aead_ctx_553648571):
      static :
        warning("Declaration of " & "struct_crypto_aead_ctx" &
            " exists but with different size")
    struct_crypto_aead_ctx
  else:
    struct_crypto_aead_ctx_553648571)
  struct_crypto_blake2b_ctx_553648577 = (when declared(struct_crypto_blake2b_ctx):
    when ownSizeof(struct_crypto_blake2b_ctx) !=
        ownSizeof(struct_crypto_blake2b_ctx_553648576):
      static :
        warning("Declaration of " & "struct_crypto_blake2b_ctx" &
            " exists but with different size")
    struct_crypto_blake2b_ctx
  else:
    struct_crypto_blake2b_ctx_553648576)
  struct_crypto_argon2_inputs_553648585 = (when declared(
      struct_crypto_argon2_inputs):
    when ownSizeof(struct_crypto_argon2_inputs) !=
        ownSizeof(struct_crypto_argon2_inputs_553648584):
      static :
        warning("Declaration of " & "struct_crypto_argon2_inputs" &
            " exists but with different size")
    struct_crypto_argon2_inputs
  else:
    struct_crypto_argon2_inputs_553648584)
  crypto_blake2b_ctx_553648579 = (when declared(crypto_blake2b_ctx):
    when ownSizeof(crypto_blake2b_ctx) != ownSizeof(crypto_blake2b_ctx_553648578):
      static :
        warning("Declaration of " & "crypto_blake2b_ctx" &
            " exists but with different size")
    crypto_blake2b_ctx
  else:
    crypto_blake2b_ctx_553648578)
  struct_crypto_argon2_extras_553648589 = (when declared(
      struct_crypto_argon2_extras):
    when ownSizeof(struct_crypto_argon2_extras) !=
        ownSizeof(struct_crypto_argon2_extras_553648588):
      static :
        warning("Declaration of " & "struct_crypto_argon2_extras" &
            " exists but with different size")
    struct_crypto_argon2_extras
  else:
    struct_crypto_argon2_extras_553648588)
  struct_crypto_argon2_config_553648581 = (when declared(
      struct_crypto_argon2_config):
    when ownSizeof(struct_crypto_argon2_config) !=
        ownSizeof(struct_crypto_argon2_config_553648580):
      static :
        warning("Declaration of " & "struct_crypto_argon2_config" &
            " exists but with different size")
    struct_crypto_argon2_config
  else:
    struct_crypto_argon2_config_553648580)
  crypto_aead_ctx_553648575 = (when declared(crypto_aead_ctx):
    when ownSizeof(crypto_aead_ctx) != ownSizeof(crypto_aead_ctx_553648574):
      static :
        warning("Declaration of " & "crypto_aead_ctx" &
            " exists but with different size")
    crypto_aead_ctx
  else:
    crypto_aead_ctx_553648574)
  crypto_argon2_inputs_553648587 = (when declared(crypto_argon2_inputs):
    when ownSizeof(crypto_argon2_inputs) != ownSizeof(crypto_argon2_inputs_553648586):
      static :
        warning("Declaration of " & "crypto_argon2_inputs" &
            " exists but with different size")
    crypto_argon2_inputs
  else:
    crypto_argon2_inputs_553648586)
  struct_crypto_poly1305_ctx_553648593 = (when declared(
      struct_crypto_poly1305_ctx):
    when ownSizeof(struct_crypto_poly1305_ctx) !=
        ownSizeof(struct_crypto_poly1305_ctx_553648592):
      static :
        warning("Declaration of " & "struct_crypto_poly1305_ctx" &
            " exists but with different size")
    struct_crypto_poly1305_ctx
  else:
    struct_crypto_poly1305_ctx_553648592)
  crypto_poly1305_ctx_553648595 = (when declared(crypto_poly1305_ctx):
    when ownSizeof(crypto_poly1305_ctx) != ownSizeof(crypto_poly1305_ctx_553648594):
      static :
        warning("Declaration of " & "crypto_poly1305_ctx" &
            " exists but with different size")
    crypto_poly1305_ctx
  else:
    crypto_poly1305_ctx_553648594)
  crypto_argon2_config_553648583 = (when declared(crypto_argon2_config):
    when ownSizeof(crypto_argon2_config) != ownSizeof(crypto_argon2_config_553648582):
      static :
        warning("Declaration of " & "crypto_argon2_config" &
            " exists but with different size")
    crypto_argon2_config
  else:
    crypto_argon2_config_553648582)
  crypto_argon2_extras_553648591 = (when declared(crypto_argon2_extras):
    when ownSizeof(crypto_argon2_extras) != ownSizeof(crypto_argon2_extras_553648590):
      static :
        warning("Declaration of " & "crypto_argon2_extras" &
            " exists but with different size")
    crypto_argon2_extras
  else:
    crypto_argon2_extras_553648590)
when not declared(struct_crypto_aead_ctx):
  type
    struct_crypto_aead_ctx* = struct_crypto_aead_ctx_553648571
else:
  static :
    hint("Declaration of " & "struct_crypto_aead_ctx" &
        " already exists, not redeclaring")
when not declared(struct_crypto_blake2b_ctx):
  type
    struct_crypto_blake2b_ctx* = struct_crypto_blake2b_ctx_553648576
else:
  static :
    hint("Declaration of " & "struct_crypto_blake2b_ctx" &
        " already exists, not redeclaring")
when not declared(struct_crypto_argon2_inputs):
  type
    struct_crypto_argon2_inputs* = struct_crypto_argon2_inputs_553648584
else:
  static :
    hint("Declaration of " & "struct_crypto_argon2_inputs" &
        " already exists, not redeclaring")
when not declared(crypto_blake2b_ctx):
  type
    crypto_blake2b_ctx* = crypto_blake2b_ctx_553648578
else:
  static :
    hint("Declaration of " & "crypto_blake2b_ctx" &
        " already exists, not redeclaring")
when not declared(struct_crypto_argon2_extras):
  type
    struct_crypto_argon2_extras* = struct_crypto_argon2_extras_553648588
else:
  static :
    hint("Declaration of " & "struct_crypto_argon2_extras" &
        " already exists, not redeclaring")
when not declared(struct_crypto_argon2_config):
  type
    struct_crypto_argon2_config* = struct_crypto_argon2_config_553648580
else:
  static :
    hint("Declaration of " & "struct_crypto_argon2_config" &
        " already exists, not redeclaring")
when not declared(crypto_aead_ctx):
  type
    crypto_aead_ctx* = crypto_aead_ctx_553648574
else:
  static :
    hint("Declaration of " & "crypto_aead_ctx" &
        " already exists, not redeclaring")
when not declared(crypto_argon2_inputs):
  type
    crypto_argon2_inputs* = crypto_argon2_inputs_553648586
else:
  static :
    hint("Declaration of " & "crypto_argon2_inputs" &
        " already exists, not redeclaring")
when not declared(struct_crypto_poly1305_ctx):
  type
    struct_crypto_poly1305_ctx* = struct_crypto_poly1305_ctx_553648592
else:
  static :
    hint("Declaration of " & "struct_crypto_poly1305_ctx" &
        " already exists, not redeclaring")
when not declared(crypto_poly1305_ctx):
  type
    crypto_poly1305_ctx* = crypto_poly1305_ctx_553648594
else:
  static :
    hint("Declaration of " & "crypto_poly1305_ctx" &
        " already exists, not redeclaring")
when not declared(crypto_argon2_config):
  type
    crypto_argon2_config* = crypto_argon2_config_553648582
else:
  static :
    hint("Declaration of " & "crypto_argon2_config" &
        " already exists, not redeclaring")
when not declared(crypto_argon2_extras):
  type
    crypto_argon2_extras* = crypto_argon2_extras_553648590
else:
  static :
    hint("Declaration of " & "crypto_argon2_extras" &
        " already exists, not redeclaring")
when not declared(CRYPTO_ARGON2_D):
  when 0 is static:
    const
      CRYPTO_ARGON2_D* = 0   ## Generated based on vendor/monocypher/monocypher.h:154:9
  else:
    let CRYPTO_ARGON2_D* = 0 ## Generated based on vendor/monocypher/monocypher.h:154:9
else:
  static :
    hint("Declaration of " & "CRYPTO_ARGON2_D" &
        " already exists, not redeclaring")
when not declared(CRYPTO_ARGON2_I):
  when 1 is static:
    const
      CRYPTO_ARGON2_I* = 1   ## Generated based on vendor/monocypher/monocypher.h:155:9
  else:
    let CRYPTO_ARGON2_I* = 1 ## Generated based on vendor/monocypher/monocypher.h:155:9
else:
  static :
    hint("Declaration of " & "CRYPTO_ARGON2_I" &
        " already exists, not redeclaring")
when not declared(CRYPTO_ARGON2_ID):
  when 2 is static:
    const
      CRYPTO_ARGON2_ID* = 2  ## Generated based on vendor/monocypher/monocypher.h:156:9
  else:
    let CRYPTO_ARGON2_ID* = 2 ## Generated based on vendor/monocypher/monocypher.h:156:9
else:
  static :
    hint("Declaration of " & "CRYPTO_ARGON2_ID" &
        " already exists, not redeclaring")
when not declared(crypto_verify16):
  proc crypto_verify16*(a: array[16'i64, uint8]; b: array[16'i64, uint8]): cint {.
      cdecl, importc: "crypto_verify16".}
else:
  static :
    hint("Declaration of " & "crypto_verify16" &
        " already exists, not redeclaring")
when not declared(crypto_verify32):
  proc crypto_verify32*(a: array[32'i64, uint8]; b: array[32'i64, uint8]): cint {.
      cdecl, importc: "crypto_verify32".}
else:
  static :
    hint("Declaration of " & "crypto_verify32" &
        " already exists, not redeclaring")
when not declared(crypto_verify64):
  proc crypto_verify64*(a: array[64'i64, uint8]; b: array[64'i64, uint8]): cint {.
      cdecl, importc: "crypto_verify64".}
else:
  static :
    hint("Declaration of " & "crypto_verify64" &
        " already exists, not redeclaring")
when not declared(crypto_wipe):
  proc crypto_wipe*(secret: pointer; size: csize_t): void {.cdecl,
      importc: "crypto_wipe".}
else:
  static :
    hint("Declaration of " & "crypto_wipe" & " already exists, not redeclaring")
when not declared(crypto_aead_lock):
  proc crypto_aead_lock*(cipher_text: ptr uint8; mac: array[16'i64, uint8];
                         key: array[32'i64, uint8]; nonce: array[24'i64, uint8];
                         ad: ptr uint8; ad_size: csize_t; plain_text: ptr uint8;
                         text_size: csize_t): void {.cdecl,
      importc: "crypto_aead_lock".}
else:
  static :
    hint("Declaration of " & "crypto_aead_lock" &
        " already exists, not redeclaring")
when not declared(crypto_aead_unlock):
  proc crypto_aead_unlock*(plain_text: ptr uint8; mac: array[16'i64, uint8];
                           key: array[32'i64, uint8];
                           nonce: array[24'i64, uint8]; ad: ptr uint8;
                           ad_size: csize_t; cipher_text: ptr uint8;
                           text_size: csize_t): cint {.cdecl,
      importc: "crypto_aead_unlock".}
else:
  static :
    hint("Declaration of " & "crypto_aead_unlock" &
        " already exists, not redeclaring")
when not declared(crypto_aead_init_x):
  proc crypto_aead_init_x*(ctx: ptr crypto_aead_ctx_553648575;
                           key: array[32'i64, uint8];
                           nonce: array[24'i64, uint8]): void {.cdecl,
      importc: "crypto_aead_init_x".}
else:
  static :
    hint("Declaration of " & "crypto_aead_init_x" &
        " already exists, not redeclaring")
when not declared(crypto_aead_init_djb):
  proc crypto_aead_init_djb*(ctx: ptr crypto_aead_ctx_553648575;
                             key: array[32'i64, uint8];
                             nonce: array[8'i64, uint8]): void {.cdecl,
      importc: "crypto_aead_init_djb".}
else:
  static :
    hint("Declaration of " & "crypto_aead_init_djb" &
        " already exists, not redeclaring")
when not declared(crypto_aead_init_ietf):
  proc crypto_aead_init_ietf*(ctx: ptr crypto_aead_ctx_553648575;
                              key: array[32'i64, uint8];
                              nonce: array[12'i64, uint8]): void {.cdecl,
      importc: "crypto_aead_init_ietf".}
else:
  static :
    hint("Declaration of " & "crypto_aead_init_ietf" &
        " already exists, not redeclaring")
when not declared(crypto_aead_write):
  proc crypto_aead_write*(ctx: ptr crypto_aead_ctx_553648575;
                          cipher_text: ptr uint8; mac: array[16'i64, uint8];
                          ad: ptr uint8; ad_size: csize_t;
                          plain_text: ptr uint8; text_size: csize_t): void {.
      cdecl, importc: "crypto_aead_write".}
else:
  static :
    hint("Declaration of " & "crypto_aead_write" &
        " already exists, not redeclaring")
when not declared(crypto_aead_read):
  proc crypto_aead_read*(ctx: ptr crypto_aead_ctx_553648575;
                         plain_text: ptr uint8; mac: array[16'i64, uint8];
                         ad: ptr uint8; ad_size: csize_t;
                         cipher_text: ptr uint8; text_size: csize_t): cint {.
      cdecl, importc: "crypto_aead_read".}
else:
  static :
    hint("Declaration of " & "crypto_aead_read" &
        " already exists, not redeclaring")
when not declared(crypto_blake2b):
  proc crypto_blake2b*(hash: ptr uint8; hash_size: csize_t; message: ptr uint8;
                       message_size: csize_t): void {.cdecl,
      importc: "crypto_blake2b".}
else:
  static :
    hint("Declaration of " & "crypto_blake2b" &
        " already exists, not redeclaring")
when not declared(crypto_blake2b_keyed):
  proc crypto_blake2b_keyed*(hash: ptr uint8; hash_size: csize_t;
                             key: ptr uint8; key_size: csize_t;
                             message: ptr uint8; message_size: csize_t): void {.
      cdecl, importc: "crypto_blake2b_keyed".}
else:
  static :
    hint("Declaration of " & "crypto_blake2b_keyed" &
        " already exists, not redeclaring")
when not declared(crypto_blake2b_init):
  proc crypto_blake2b_init*(ctx: ptr crypto_blake2b_ctx_553648579;
                            hash_size: csize_t): void {.cdecl,
      importc: "crypto_blake2b_init".}
else:
  static :
    hint("Declaration of " & "crypto_blake2b_init" &
        " already exists, not redeclaring")
when not declared(crypto_blake2b_keyed_init):
  proc crypto_blake2b_keyed_init*(ctx: ptr crypto_blake2b_ctx_553648579;
                                  hash_size: csize_t; key: ptr uint8;
                                  key_size: csize_t): void {.cdecl,
      importc: "crypto_blake2b_keyed_init".}
else:
  static :
    hint("Declaration of " & "crypto_blake2b_keyed_init" &
        " already exists, not redeclaring")
when not declared(crypto_blake2b_update):
  proc crypto_blake2b_update*(ctx: ptr crypto_blake2b_ctx_553648579;
                              message: ptr uint8; message_size: csize_t): void {.
      cdecl, importc: "crypto_blake2b_update".}
else:
  static :
    hint("Declaration of " & "crypto_blake2b_update" &
        " already exists, not redeclaring")
when not declared(crypto_blake2b_final):
  proc crypto_blake2b_final*(ctx: ptr crypto_blake2b_ctx_553648579;
                             hash: ptr uint8): void {.cdecl,
      importc: "crypto_blake2b_final".}
else:
  static :
    hint("Declaration of " & "crypto_blake2b_final" &
        " already exists, not redeclaring")
when not declared(crypto_argon2_no_extras):
  var crypto_argon2_no_extras* {.importc: "crypto_argon2_no_extras".}: crypto_argon2_extras_553648591
else:
  static :
    hint("Declaration of " & "crypto_argon2_no_extras" &
        " already exists, not redeclaring")
when not declared(crypto_argon2):
  proc crypto_argon2*(hash: ptr uint8; hash_size: uint32; work_area: pointer;
                      config: crypto_argon2_config_553648583;
                      inputs: crypto_argon2_inputs_553648587;
                      extras: crypto_argon2_extras_553648591): void {.cdecl,
      importc: "crypto_argon2".}
else:
  static :
    hint("Declaration of " & "crypto_argon2" &
        " already exists, not redeclaring")
when not declared(crypto_x25519_public_key):
  proc crypto_x25519_public_key*(public_key: array[32'i64, uint8];
                                 secret_key: array[32'i64, uint8]): void {.
      cdecl, importc: "crypto_x25519_public_key".}
else:
  static :
    hint("Declaration of " & "crypto_x25519_public_key" &
        " already exists, not redeclaring")
when not declared(crypto_x25519):
  proc crypto_x25519*(raw_shared_secret: array[32'i64, uint8];
                      your_secret_key: array[32'i64, uint8];
                      their_public_key: array[32'i64, uint8]): void {.cdecl,
      importc: "crypto_x25519".}
else:
  static :
    hint("Declaration of " & "crypto_x25519" &
        " already exists, not redeclaring")
when not declared(crypto_x25519_to_eddsa):
  proc crypto_x25519_to_eddsa*(eddsa: array[32'i64, uint8];
                               x25519: array[32'i64, uint8]): void {.cdecl,
      importc: "crypto_x25519_to_eddsa".}
else:
  static :
    hint("Declaration of " & "crypto_x25519_to_eddsa" &
        " already exists, not redeclaring")
when not declared(crypto_x25519_inverse):
  proc crypto_x25519_inverse*(blind_salt: array[32'i64, uint8];
                              private_key: array[32'i64, uint8];
                              curve_point: array[32'i64, uint8]): void {.cdecl,
      importc: "crypto_x25519_inverse".}
else:
  static :
    hint("Declaration of " & "crypto_x25519_inverse" &
        " already exists, not redeclaring")
when not declared(crypto_x25519_dirty_small):
  proc crypto_x25519_dirty_small*(pk: array[32'i64, uint8];
                                  sk: array[32'i64, uint8]): void {.cdecl,
      importc: "crypto_x25519_dirty_small".}
else:
  static :
    hint("Declaration of " & "crypto_x25519_dirty_small" &
        " already exists, not redeclaring")
when not declared(crypto_x25519_dirty_fast):
  proc crypto_x25519_dirty_fast*(pk: array[32'i64, uint8];
                                 sk: array[32'i64, uint8]): void {.cdecl,
      importc: "crypto_x25519_dirty_fast".}
else:
  static :
    hint("Declaration of " & "crypto_x25519_dirty_fast" &
        " already exists, not redeclaring")
when not declared(crypto_eddsa_key_pair):
  proc crypto_eddsa_key_pair*(secret_key: array[64'i64, uint8];
                              public_key: array[32'i64, uint8];
                              seed: array[32'i64, uint8]): void {.cdecl,
      importc: "crypto_eddsa_key_pair".}
else:
  static :
    hint("Declaration of " & "crypto_eddsa_key_pair" &
        " already exists, not redeclaring")
when not declared(crypto_eddsa_sign):
  proc crypto_eddsa_sign*(signature: array[64'i64, uint8];
                          secret_key: array[64'i64, uint8]; message: ptr uint8;
                          message_size: csize_t): void {.cdecl,
      importc: "crypto_eddsa_sign".}
else:
  static :
    hint("Declaration of " & "crypto_eddsa_sign" &
        " already exists, not redeclaring")
when not declared(crypto_eddsa_check):
  proc crypto_eddsa_check*(signature: array[64'i64, uint8];
                           public_key: array[32'i64, uint8]; message: ptr uint8;
                           message_size: csize_t): cint {.cdecl,
      importc: "crypto_eddsa_check".}
else:
  static :
    hint("Declaration of " & "crypto_eddsa_check" &
        " already exists, not redeclaring")
when not declared(crypto_eddsa_to_x25519):
  proc crypto_eddsa_to_x25519*(x25519: array[32'i64, uint8];
                               eddsa: array[32'i64, uint8]): void {.cdecl,
      importc: "crypto_eddsa_to_x25519".}
else:
  static :
    hint("Declaration of " & "crypto_eddsa_to_x25519" &
        " already exists, not redeclaring")
when not declared(crypto_eddsa_trim_scalar):
  proc crypto_eddsa_trim_scalar*(out_arg: array[32'i64, uint8];
                                 in_arg: array[32'i64, uint8]): void {.cdecl,
      importc: "crypto_eddsa_trim_scalar".}
else:
  static :
    hint("Declaration of " & "crypto_eddsa_trim_scalar" &
        " already exists, not redeclaring")
when not declared(crypto_eddsa_reduce):
  proc crypto_eddsa_reduce*(reduced: array[32'i64, uint8];
                            expanded: array[64'i64, uint8]): void {.cdecl,
      importc: "crypto_eddsa_reduce".}
else:
  static :
    hint("Declaration of " & "crypto_eddsa_reduce" &
        " already exists, not redeclaring")
when not declared(crypto_eddsa_mul_add):
  proc crypto_eddsa_mul_add*(r: array[32'i64, uint8]; a: array[32'i64, uint8];
                             b: array[32'i64, uint8]; c: array[32'i64, uint8]): void {.
      cdecl, importc: "crypto_eddsa_mul_add".}
else:
  static :
    hint("Declaration of " & "crypto_eddsa_mul_add" &
        " already exists, not redeclaring")
when not declared(crypto_eddsa_scalarbase):
  proc crypto_eddsa_scalarbase*(point: array[32'i64, uint8];
                                scalar: array[32'i64, uint8]): void {.cdecl,
      importc: "crypto_eddsa_scalarbase".}
else:
  static :
    hint("Declaration of " & "crypto_eddsa_scalarbase" &
        " already exists, not redeclaring")
when not declared(crypto_eddsa_check_equation):
  proc crypto_eddsa_check_equation*(signature: array[64'i64, uint8];
                                    public_key: array[32'i64, uint8];
                                    h_ram: array[32'i64, uint8]): cint {.cdecl,
      importc: "crypto_eddsa_check_equation".}
else:
  static :
    hint("Declaration of " & "crypto_eddsa_check_equation" &
        " already exists, not redeclaring")
when not declared(crypto_chacha20_h):
  proc crypto_chacha20_h*(out_arg: array[32'i64, uint8];
                          key: array[32'i64, uint8];
                          in_arg: array[16'i64, uint8]): void {.cdecl,
      importc: "crypto_chacha20_h".}
else:
  static :
    hint("Declaration of " & "crypto_chacha20_h" &
        " already exists, not redeclaring")
when not declared(crypto_chacha20_djb):
  proc crypto_chacha20_djb*(cipher_text: ptr uint8; plain_text: ptr uint8;
                            text_size: csize_t; key: array[32'i64, uint8];
                            nonce: array[8'i64, uint8]; ctr: uint64): uint64 {.
      cdecl, importc: "crypto_chacha20_djb".}
else:
  static :
    hint("Declaration of " & "crypto_chacha20_djb" &
        " already exists, not redeclaring")
when not declared(crypto_chacha20_ietf):
  proc crypto_chacha20_ietf*(cipher_text: ptr uint8; plain_text: ptr uint8;
                             text_size: csize_t; key: array[32'i64, uint8];
                             nonce: array[12'i64, uint8]; ctr: uint32): uint32 {.
      cdecl, importc: "crypto_chacha20_ietf".}
else:
  static :
    hint("Declaration of " & "crypto_chacha20_ietf" &
        " already exists, not redeclaring")
when not declared(crypto_chacha20_x):
  proc crypto_chacha20_x*(cipher_text: ptr uint8; plain_text: ptr uint8;
                          text_size: csize_t; key: array[32'i64, uint8];
                          nonce: array[24'i64, uint8]; ctr: uint64): uint64 {.
      cdecl, importc: "crypto_chacha20_x".}
else:
  static :
    hint("Declaration of " & "crypto_chacha20_x" &
        " already exists, not redeclaring")
when not declared(crypto_poly1305):
  proc crypto_poly1305*(mac: array[16'i64, uint8]; message: ptr uint8;
                        message_size: csize_t; key: array[32'i64, uint8]): void {.
      cdecl, importc: "crypto_poly1305".}
else:
  static :
    hint("Declaration of " & "crypto_poly1305" &
        " already exists, not redeclaring")
when not declared(crypto_poly1305_init):
  proc crypto_poly1305_init*(ctx: ptr crypto_poly1305_ctx_553648595;
                             key: array[32'i64, uint8]): void {.cdecl,
      importc: "crypto_poly1305_init".}
else:
  static :
    hint("Declaration of " & "crypto_poly1305_init" &
        " already exists, not redeclaring")
when not declared(crypto_poly1305_update):
  proc crypto_poly1305_update*(ctx: ptr crypto_poly1305_ctx_553648595;
                               message: ptr uint8; message_size: csize_t): void {.
      cdecl, importc: "crypto_poly1305_update".}
else:
  static :
    hint("Declaration of " & "crypto_poly1305_update" &
        " already exists, not redeclaring")
when not declared(crypto_poly1305_final):
  proc crypto_poly1305_final*(ctx: ptr crypto_poly1305_ctx_553648595;
                              mac: array[16'i64, uint8]): void {.cdecl,
      importc: "crypto_poly1305_final".}
else:
  static :
    hint("Declaration of " & "crypto_poly1305_final" &
        " already exists, not redeclaring")
when not declared(crypto_elligator_map):
  proc crypto_elligator_map*(curve: array[32'i64, uint8];
                             hidden: array[32'i64, uint8]): void {.cdecl,
      importc: "crypto_elligator_map".}
else:
  static :
    hint("Declaration of " & "crypto_elligator_map" &
        " already exists, not redeclaring")
when not declared(crypto_elligator_rev):
  proc crypto_elligator_rev*(hidden: array[32'i64, uint8];
                             curve: array[32'i64, uint8]; tweak: uint8): cint {.
      cdecl, importc: "crypto_elligator_rev".}
else:
  static :
    hint("Declaration of " & "crypto_elligator_rev" &
        " already exists, not redeclaring")
when not declared(crypto_elligator_key_pair):
  proc crypto_elligator_key_pair*(hidden: array[32'i64, uint8];
                                  secret_key: array[32'i64, uint8];
                                  seed: array[32'i64, uint8]): void {.cdecl,
      importc: "crypto_elligator_key_pair".}
else:
  static :
    hint("Declaration of " & "crypto_elligator_key_pair" &
        " already exists, not redeclaring")