# js Binary Schema Parser

Parse binary files in javascript using a schema to convert to plain objects.

Years ago I needed to parse GIF images for our **[Ruffle][1]** messaging app. While this readme describes how to parse binary files in general, our _[GIF Parser][2]_ library exhibits a full use of this library (including a _[demo][2]_). I suggest looking at the other library for a quick understanding.

Basically, you provide a schema object and some data, and it will step through the binary data, and convert it into the object defined by your schema. Included in this library is a parser for the `Uint8TypedArray`, but it is easy to add them for your own types if necessary. It can parse bytes, arrays, chunks, conditionals, loops, etc.

### How to Use

_Installation:_

    npm install js-binary-schema-parser

_Create a schema and parse a file:_

    import { parse, conditional } from 'js-binary-schema-parser'
    import { buildStream, readByte } from 'js-binary-schema-parser/lib/parsers/uint8'

    const schema = [
      // part definitions...
      { someKey: readByte() }
    ];

    // get the input file data
    const data = new Uint8Array(fileArrayBuffer);
    // create a stream object and parse it
    const parsedObject = parse(buildStream(data), schema)

### Schemas

So far in this library there is only one built in schema, which is for the GIF format. You can import included schemas like:

    import GIF from 'js-binary-schema-parser/lib/schemas/gif'

Schemas are an array of _parts_, which are objects containing a single key label, and the parser to use at that point in time. This format was chosen to ensure parse ordering was consistent. _Parts_ can also contain other parts internally, and include syntax for loops, and conditionals. You can also include your own custom functions for parsing, providing direct access to the given data stream. Below is an example of a schema using the `Uint8TypedArray` parser provided to parse the GIF format header. You can also see a full example [here][2] of parsing entire GIF files.

### Example

    var gifSchema = [
    	{
    		label: 'header', // gif header
    		parts: [
    			{ label: 'signature', parser: Parsers.readString(3) },
    			{ label: 'version', parser: Parsers.readString(3) }
    		]
    	},{
    		label: 'lsd', // local screen descriptor
    		parts: [
    			{ label: 'width', parser: Parsers.readUnsigned(true) },
    			{ label: 'height', parser: Parsers.readUnsigned(true) },
    			{ label: 'gct', bits: {
    				exists: { index: 0 },
    				resolution: { index: 1, length: 3 },
    				sort: { index: 4 },
    				size: { index: 5, length: 3 }
    			}},
    			{ label: 'backgroundColorIndex', parser: Parsers.readByte() },
    			{ label: 'pixelAspectRatio', parser: Parsers.readByte() }
    		]
    	}
    ];

### Why this parser?

There are other good parsers around, like [jBinary][4], but we weren't a fan of relying on object key ordering, and defining parser types as strings. This one is also extremely small, and easily exstensible in any way you want.

### Demo

You can see a full demo **[here][2]** which uses this lib to parse GIF files for manipulation.

### Who are we?

[Matt Way][3] & [Nick Drewe][5]

[Wethrift.com][6]

[1]: https://www.producthunt.com/posts/ruffle
[2]: https://github.com/matt-way/gifuct-js
[3]: https://twitter.com/_MattWay
[4]: https://github.com/jDataView/jBinary
[5]: https://twitter.com/nickdrewe
[6]: https://wethrift.com
