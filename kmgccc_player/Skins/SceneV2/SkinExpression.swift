import Foundation

/// The scene expression language: arithmetic, comparison, conditionals, member access and a
/// fixed function table. There are no loops, assignments or user functions, so the cost of
/// every expression is bounded by its size.
indirect enum SkinExpr: Equatable {
    case literal(SkinValue)
    /// A dotted identifier chain, resolved against the data schema by the compiler.
    case path([String])
    case member(SkinExpr, String)
    case index(SkinExpr, SkinExpr)
    case call(String, [SkinExpr])
    case unary(SkinUnaryOperator, SkinExpr)
    case binary(SkinBinaryOperator, SkinExpr, SkinExpr)
    case conditional(SkinExpr, SkinExpr, SkinExpr)
    case list([SkinExpr])
}

enum SkinUnaryOperator: String { case negate = "-", not = "!" }

enum SkinBinaryOperator: String {
    case add = "+", subtract = "-", multiply = "*", divide = "/", remainder = "%"
    case equal = "==", notEqual = "!=", less = "<", lessOrEqual = "<=", greater = ">", greaterOrEqual = ">="
    case and = "&&", or = "||", coalesce = "??"
}

struct SkinExpressionError: Error, Equatable, LocalizedError {
    let message: String
    let offset: Int
    var errorDescription: String? { "\(message)（第 \(offset + 1) 个字符）" }
}

enum SkinExpressionParser {
    static let maximumLength = 4000
    static let maximumDepth = 48

    /// Parses the text after the leading `=`.
    static func parse(_ source: String) throws -> SkinExpr {
        guard source.count <= maximumLength else {
            throw SkinExpressionError(message: "表达式过长", offset: maximumLength)
        }
        var lexer = Lexer(source)
        var parser = Parser(tokens: try lexer.tokens())
        let expression = try parser.expression(depth: 0)
        guard parser.current.kind == .end else {
            throw SkinExpressionError(message: "无法识别“\(parser.current.text)”", offset: parser.current.offset)
        }
        return expression
    }
}

private struct Token: Equatable {
    enum Kind: Equatable { case number, string, identifier, color, symbol, end }
    let kind: Kind
    let text: String
    let offset: Int
}

private struct Lexer {
    private let characters: [Character]
    private var position = 0

    init(_ source: String) { characters = Array(source) }

    mutating func tokens() throws -> [Token] {
        var result: [Token] = []
        while true {
            skipWhitespace()
            guard position < characters.count else {
                result.append(Token(kind: .end, text: "", offset: position))
                return result
            }
            result.append(try next())
        }
    }

    private mutating func skipWhitespace() {
        while position < characters.count, characters[position].isWhitespace { position += 1 }
    }

    private mutating func next() throws -> Token {
        let start = position
        let character = characters[position]
        if character.isNumber || (character == "." && peek(1)?.isNumber == true) {
            var text = ""
            while position < characters.count, characters[position].isNumber || characters[position] == "." {
                text.append(characters[position]); position += 1
            }
            if position < characters.count, characters[position] == "e" || characters[position] == "E" {
                let exponentStart = position
                text.append(characters[position]); position += 1
                if position < characters.count, characters[position] == "-" || characters[position] == "+" {
                    text.append(characters[position]); position += 1
                }
                guard position < characters.count, characters[position].isNumber else {
                    throw SkinExpressionError(message: "数字指数不完整", offset: exponentStart)
                }
                while position < characters.count, characters[position].isNumber {
                    text.append(characters[position]); position += 1
                }
            }
            guard Double(text) != nil else { throw SkinExpressionError(message: "数字格式不正确", offset: start) }
            return Token(kind: .number, text: text, offset: start)
        }
        if character.isLetter || character == "_" || character == "$" {
            var text = ""
            while position < characters.count,
                  characters[position].isLetter || characters[position].isNumber || characters[position] == "_" || characters[position] == "$" {
                text.append(characters[position]); position += 1
            }
            return Token(kind: .identifier, text: text, offset: start)
        }
        if character == "\"" || character == "'" {
            position += 1
            var text = ""
            while position < characters.count, characters[position] != character {
                if characters[position] == "\\", position + 1 < characters.count {
                    position += 1
                    switch characters[position] {
                    case "n": text.append("\n")
                    case "t": text.append("\t")
                    default: text.append(characters[position])
                    }
                } else {
                    text.append(characters[position])
                }
                position += 1
            }
            guard position < characters.count else { throw SkinExpressionError(message: "字符串没有结束", offset: start) }
            position += 1
            return Token(kind: .string, text: text, offset: start)
        }
        if character == "#" {
            var text = "#"
            position += 1
            while position < characters.count, characters[position].isHexDigit {
                text.append(characters[position]); position += 1
            }
            guard OKLCHColor(named: text) != nil else { throw SkinExpressionError(message: "颜色格式不正确", offset: start) }
            return Token(kind: .color, text: text, offset: start)
        }
        for symbol in ["==", "!=", "<=", ">=", "&&", "||", "??"] where matches(symbol) {
            position += symbol.count
            return Token(kind: .symbol, text: symbol, offset: start)
        }
        guard "+-*/%!<>?:.,()[]".contains(character) else {
            throw SkinExpressionError(message: "无法识别“\(character)”", offset: start)
        }
        position += 1
        return Token(kind: .symbol, text: String(character), offset: start)
    }

    private func peek(_ distance: Int) -> Character? {
        let index = position + distance
        return index < characters.count ? characters[index] : nil
    }

    private func matches(_ symbol: String) -> Bool {
        let expected = Array(symbol)
        guard position + expected.count <= characters.count else { return false }
        return Array(characters[position..<(position + expected.count)]) == expected
    }
}

private struct Parser {
    let tokens: [Token]
    var index = 0

    init(tokens: [Token]) { self.tokens = tokens }

    var current: Token { tokens[min(index, tokens.count - 1)] }

    private mutating func advance() -> Token {
        let token = current
        if index < tokens.count - 1 { index += 1 }
        return token
    }

    private func isSymbol(_ text: String) -> Bool { current.kind == .symbol && current.text == text }

    private mutating func expect(_ text: String) throws {
        guard isSymbol(text) else {
            throw SkinExpressionError(message: "这里需要“\(text)”", offset: current.offset)
        }
        _ = advance()
    }

    private func checkDepth(_ depth: Int) throws {
        guard depth < SkinExpressionParser.maximumDepth else {
            throw SkinExpressionError(message: "表达式嵌套过深", offset: current.offset)
        }
    }

    mutating func expression(depth: Int) throws -> SkinExpr {
        try checkDepth(depth)
        let condition = try binary(precedence: 0, depth: depth + 1)
        guard isSymbol("?") else { return condition }
        _ = advance()
        let whenTrue = try expression(depth: depth + 1)
        try expect(":")
        let whenFalse = try expression(depth: depth + 1)
        return .conditional(condition, whenTrue, whenFalse)
    }

    private static let levels: [[SkinBinaryOperator]] = [
        [.coalesce], [.or], [.and], [.equal, .notEqual],
        [.less, .lessOrEqual, .greater, .greaterOrEqual],
        [.add, .subtract], [.multiply, .divide, .remainder],
    ]

    /// Precedence levels are one grammar step, not author nesting, so they share the caller's depth.
    private mutating func binary(precedence: Int, depth: Int) throws -> SkinExpr {
        try checkDepth(depth)
        guard precedence < Self.levels.count else { return try unary(depth: depth) }
        var lhs = try binary(precedence: precedence + 1, depth: depth)
        while current.kind == .symbol,
              let operation = SkinBinaryOperator(rawValue: current.text),
              Self.levels[precedence].contains(operation) {
            _ = advance()
            let rhs = try binary(precedence: precedence + 1, depth: depth)
            lhs = .binary(operation, lhs, rhs)
        }
        return lhs
    }

    private mutating func unary(depth: Int) throws -> SkinExpr {
        try checkDepth(depth)
        if isSymbol("-") { _ = advance(); return .unary(.negate, try unary(depth: depth + 1)) }
        if isSymbol("!") { _ = advance(); return .unary(.not, try unary(depth: depth + 1)) }
        return try postfix(depth: depth)
    }

    private mutating func postfix(depth: Int) throws -> SkinExpr {
        var result = try primary(depth: depth)
        while true {
            if isSymbol(".") {
                _ = advance()
                guard current.kind == .identifier else {
                    throw SkinExpressionError(message: "“.”后需要字段名", offset: current.offset)
                }
                let name = advance().text
                if case .path(let components) = result {
                    result = .path(components + [name])
                } else {
                    result = .member(result, name)
                }
            } else if isSymbol("[") {
                _ = advance()
                let subscriptExpression = try expression(depth: depth + 1)
                try expect("]")
                result = .index(result, subscriptExpression)
            } else {
                return result
            }
        }
    }

    private mutating func primary(depth: Int) throws -> SkinExpr {
        try checkDepth(depth)
        let token = current
        switch token.kind {
        case .number:
            _ = advance()
            return .literal(.number(Double(token.text) ?? 0))
        case .string:
            _ = advance()
            return .literal(.text(token.text))
        case .color:
            _ = advance()
            return .literal(.color(OKLCHColor(named: token.text) ?? .black))
        case .identifier:
            _ = advance()
            switch token.text {
            case "true": return .literal(.boolean(true))
            case "false": return .literal(.boolean(false))
            case "null": return .literal(.null)
            case "pi": return .literal(.number(.pi))
            default: break
            }
            if isSymbol("(") {
                _ = advance()
                var arguments: [SkinExpr] = []
                if !isSymbol(")") {
                    repeat {
                        if isSymbol(",") { _ = advance() }
                        arguments.append(try expression(depth: depth + 1))
                    } while isSymbol(",")
                }
                try expect(")")
                return .call(token.text, arguments)
            }
            return .path([token.text])
        case .symbol where token.text == "(":
            _ = advance()
            let inner = try expression(depth: depth + 1)
            try expect(")")
            return inner
        case .symbol where token.text == "[":
            _ = advance()
            var items: [SkinExpr] = []
            if !isSymbol("]") {
                repeat {
                    if isSymbol(",") { _ = advance() }
                    items.append(try expression(depth: depth + 1))
                } while isSymbol(",")
            }
            try expect("]")
            return .list(items)
        case .end:
            throw SkinExpressionError(message: "表达式不完整", offset: token.offset)
        default:
            throw SkinExpressionError(message: "无法识别“\(token.text)”", offset: token.offset)
        }
    }
}
