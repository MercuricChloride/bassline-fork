#!/usr/bin/env node
// @ts-check

// The pantry CLI — a thin human skin over the home's three methods.
// Values go to stdout: rendered as text on a tty, canonical bytes when
// piped. Human notes go around them, on stderr.
/** @import {Value} from '@bassline/core/data' */
import { readFileSync } from 'node:fs'
import { userInfo } from 'node:os'
import { read, print } from '@bassline/core/text'
import { encode, record, symbol, string, int } from '@bassline/core/data'
import {
  open,
  DEFAULT_STORE,
  loadValues,
  parseValues,
  saveValues,
  refOf,
  hashOf,
  hex,
} from '../src/index.js'

const USAGE = `pantry — a home for values

usage: pantry [--store <path>] <command> [...]

  hold [file ...]              hold every value in the files (or stdin);
                               prints each value's denotation
  solve <value>                follow what a value denotes to ground;
                               a frontier value comes back unchanged
  run <reading>                run a reading, e.g. '(census)' '(speech)'
                               '(find (means \`s \`d))' '(expand <v>)'
  name <sign> <denoted> [--via <value>]
                               sugar: hold (means sign denoted via)
  adopt <file> [--into <db>]   adopt every value in a file — a (speech #{…})
                               report is uttered member by member, a
                               (custody #{…}) report is merely kept
  export <file> [--text]       write the speech report as one value;
                               .blb binary, .blt text
  sweep --older-than <dur> [--commit]
                               sugar: run (sweep <ms> [commit]); dry run
                               unless --commit (durations: 30d 12h 45m 2w)

  --store <path>               store file (default ${DEFAULT_STORE}; env PANTRY)
  --text | --binary            force output form (default: text on a tty)
`

const VALUED = new Set(['--store', '--via', '--older-than', '--into'])

function parseArgv(argv) {
  const flags = {}
  const args = []
  let cmd = null
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a.startsWith('--')) {
      if (VALUED.has(a)) {
        flags[a.slice(2)] = argv[++i]
        if (flags[a.slice(2)] === undefined) die(`${a} needs a value`)
      } else flags[a.slice(2)] = true
    } else if (cmd === null) cmd = a
    else args.push(a)
  }
  return { cmd, args, flags }
}

/**
 * @param {string} msg
 * @returns {never}
 */
function die(msg) {
  process.stderr.write(`pantry: ${msg}\n`)
  process.exit(1)
}

const note = s => process.stderr.write(s + '\n')
const say = s => process.stdout.write(s + '\n')

/**
 * Parse one value from a CLI argument.
 * @param {string} s
 * @returns {Value}
 */
function argValue(s) {
  const vs = read(s)
  if (vs.length !== 1) die(`expected one value, got ${vs.length}: ${s}`)
  return vs[0]
}

/**
 * @param {Value} v
 * @param {{text?: boolean, binary?: boolean}} flags
 */
function emitValue(v, flags) {
  const text = flags.text || (!flags.binary && process.stdout.isTTY)
  if (text) process.stdout.write(print(v) + '\n')
  else process.stdout.write(encode(v))
}

/** @param {string} s duration like 30d, 12h, 45m, 10s, 2w */
function parseDuration(s) {
  const m = /^(\d+)([smhdw])$/.exec(s)
  if (!m) die(`bad duration: ${s} (use e.g. 30d, 12h, 45m, 10s, 2w)`)
  const n = Number(m[1])
  const unit = {
    s: 1000,
    m: 60_000,
    h: 3_600_000,
    d: 86_400_000,
    w: 604_800_000,
  }[m[2]]
  return n * unit
}

/**
 * A bare 32-byte bytes value on the command line is a hash; wrap it into
 * its reference record. Anything else passes through. CLI sugar only —
 * the home itself never guesses.
 * @param {Value} v
 */
function wrapHash(v) {
  if (v.kind === 'bytes' && !v.actionable && v.value.length === 32)
    return refOf(v.value)
  return v
}

/** The default warrant for CLI naming facts: (said <user> <iso-time>). */
function saidVia() {
  let who = 'someone'
  try {
    who = userInfo().username
  } catch {
    /* keep the default */
  }
  return record([symbol('said'), string(who), string(new Date().toISOString())])
}

function readStdin() {
  const buf = readFileSync(0)
  if (buf.length === 0) return []
  return parseValues(buf)
}

function main() {
  const { cmd, args, flags } = parseArgv(process.argv.slice(2))
  if (!cmd || flags.help) {
    process.stdout.write(USAGE)
    process.exit(cmd ? 0 : 1)
  }

  const storePath = flags.store ?? process.env.PANTRY ?? DEFAULT_STORE
  // lazy: a command that never touches the primary store must not open
  // (or create) it — adopt --into is why
  /** @type {ReturnType<typeof open> | null} */
  let opened = null
  const p = () => (opened ??= open(storePath))

  switch (cmd) {
    case 'hold': {
      const batches =
        args.length > 0
          ? args.map(f => ({ from: f, values: loadValues(f) }))
          : [{ from: 'stdin', values: readStdin() }]
      for (const { from, values } of batches) {
        if (values.length === 0) note(`${from}: no values`)
        for (const v of values) emitValue(p().hold(v), flags)
      }
      break
    }

    case 'solve': {
      if (args.length !== 1) die('solve needs one value')
      emitValue(p().solve(argValue(args[0])), flags)
      break
    }

    case 'run': {
      if (args.length !== 1) die('run needs one reading')
      emitValue(p().run(argValue(args[0])), flags)
      break
    }

    case 'name': {
      if (args.length !== 2) die('name needs <sign> <denoted>')
      const via = flags.via ? argValue(flags.via) : saidVia()
      const fact = record([
        symbol('means'),
        argValue(args[0]),
        wrapHash(argValue(args[1])),
        via,
      ])
      p().hold(fact)
      emitValue(fact, flags)
      break
    }

    case 'adopt': {
      if (args.length !== 1) die('adopt needs a file path')
      const target = flags.into ? open(flags.into) : p()
      let adopted = 0
      for (const v of loadValues(args[0])) {
        const r = target.run(record([symbol('adopt'), v]))
        adopted += Number(r.value[1].value)
      }
      note(`adopted ${adopted}`)
      if (flags.into) target.close()
      break
    }

    case 'export': {
      if (args.length !== 1) die('export needs a file path')
      const doc = p().run(record([symbol('speech')]))
      saveValues(args[0], [doc], { text: !!flags.text })
      note(
        `speech #[${hex(hashOf(doc))}] · ${doc.value[1].value.length} members`
      )
      break
    }

    case 'sweep': {
      if (!flags['older-than']) die('sweep requires --older-than <duration>')
      const fields = [int(parseDuration(flags['older-than']))]
      if (flags.commit) fields.push(symbol('commit'))
      const r = p().run(record([symbol('sweep'), ...fields]))
      const committed = r.value.some(
        f => f.kind === 'symbol' && f.value === 'committed'
      )
      const verb = committed ? 'swept' : 'sweepable'
      const tail = committed ? '' : ' (dry run — pass --commit)'
      say(
        `${verb} ${r.value[1].value} values · ${r.value[2].value} bytes${tail}`
      )
      break
    }

    default:
      die(`unknown command: ${cmd}\n\n${USAGE}`)
  }

  opened?.close()
}

try {
  main()
} catch (e) {
  die(e instanceof Error ? e.message : String(e))
}
