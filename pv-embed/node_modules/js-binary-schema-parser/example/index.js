import fs from 'fs'
import { parse } from '../src'
import { buildStream } from '../src/parsers/uint8'
import { GIF } from '../src/schemas'

debugger

const data = fs.readFileSync('./example/dog.gif')
const result = parse(buildStream(new Uint8Array(data)), GIF)
console.log(result)
