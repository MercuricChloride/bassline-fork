## the jam plugin's launchers: claude-jam and jam-mcp

import cli

suite "jam plugin":
  let plugin = bin / ".." / ".." / "jam-plugin" / "bin"
  let home = tmp / "home"

  test "claude-jam keeps one key for a name, made the first time it comes":
    fake "claude", "echo \"$@\""
    let run = proc(name: string): tuple[output: string, exitCode: int] =
      execCmdEx(quoteShell(plugin / "claude-jam") & " " & quoteShell(name) & " --continue",
                env = withEnv({"HOME": home}))
    let r = run("tester")
    check r.exitCode == 0
    check "--continue --dangerously-load-development-channels plugin:jam@skills-dir" in r.output
    let key = home / ".bl" / "keys" / "tester.blb"
    check fileExists(key)
    check getFilePermissions(key) == {fpUserRead, fpUserWrite}
    let first = readFile(key)
    check run("tester").exitCode == 0
    check readFile(key) == first               # kept, not made again
    let bad = run("../tester")
    check "speaks unsigned" in bad.output
    check toSeq(walkDir(home / ".bl" / "keys")).len == 1

  test "jam-mcp signs with the key kept for its name, and speaks unsigned without one":
    let jam = jamServe()
    let line = jam.asking(blb("(general)"))
    var signing = begun startProcess(plugin / "jam-mcp", args = ["--at", ":" & jam.port],
                                     env = withEnv({"HOME": home, "JAM_NAME": "tester"}),
                                     options = {})
    let kp = Keypair.fromValue(decoded(readFile(home / ".bl" / "keys" / "tester.blb"))[0])
    let me = "!{(identity tester) (identity " & $bytes(@(kp.pubkey)) & ")}"
    check signing.call(1, "tell", %*{"value": "(general !{(by " & me & ") (said \"signed hi\")})"}).
      startsWith("(put general ")
    var plain = begun startProcess(plugin / "jam-mcp", args = ["--at", ":" & jam.port],
                                   env = withEnv({"HOME": home, "JAM_NAME": "keyless"}),
                                   options = {})
    check plain.call(1, "tell", %*{"value": "(general !{(by keyless) (said \"plain hi\")})"}).
      startsWith("(put general ")
    let told = line.told
    check told.len == 2
    check told[0].items[2].kind == bRec and told[0].items[2].items[0] == sym"signed"
    check heard(told[0]).get.vouched
    check told[1].items[2].answer(sym"by") == some sym"keyless"
    signing.leave()
    plain.leave()
    line.close()
    discard jam.stop
