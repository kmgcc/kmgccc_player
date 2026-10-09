import CryptoKit
import Foundation

nonisolated enum DSPScriptCompiler {
    static let maximumSourceBytes = 64 * 1_024
    static let maximumParameterCount = 32
    static let maximumStateBytes = 4 * 1_024 * 1_024
    static let maximumLatencyFrames = 2_048
    static let maximumWeightedOperationsPerSecond = 24_000_000.0
    static let maximumChannelCount = 32
    static let maximumSampleRate = 768_000.0
    static let maximumCachedPrograms = 32
    static let maximumCachedArtifactBytes = 16 * 1_024 * 1_024
    static let maximumChainWeightedOperationsPerSecond = 48_000_000.0
    // Keep this nominal block size aligned with the renderer enqueue contract.
    // Short EOF/split blocks and transition warmup need separate benchmarks.
    static let costEstimateBlockFrames = 2_048

    static func estimatedRendererOperationsPerSecond(baseOperationsPerSecond: Double, latencyFrames: Int) -> Double {
        baseOperationsPerSecond * (1 + Double(max(0, latencyFrames)) / Double(costEstimateBlockFrames))
    }

    private static let maximumTokenCount = 8_192
    private static let maximumInstructionCount = 8_192
    private static let maximumExpressionDepth = 64

    private struct Location: Sendable {
        let line: Int
        let column: Int
    }

    private enum TokenKind: Equatable {
        case identifier
        case number
        case symbol
        case end
    }

    private struct Token {
        let kind: TokenKind
        let text: String
        let location: Location
        let number: Double?
    }

    private struct Lexer {
        let scalars: [UnicodeScalar]
        var index = 0
        var line = 1
        var column = 1

        init(source: String) {
            scalars = Array(source.unicodeScalars)
        }

        mutating func lex() throws -> [Token] {
            var tokens = [Token]()
            tokens.reserveCapacity(min(scalars.count, DSPScriptCompiler.maximumTokenCount))
            while true {
                try skipTrivia()
                let location = Location(line: line, column: column)
                guard let scalar = current else {
                    guard tokens.count < DSPScriptCompiler.maximumTokenCount else {
                        throw DSPScriptCompiler.failure(
                            "script.tokenBudgetExceeded",
                            "The script contains too many tokens.",
                            at: location
                        )
                    }
                    tokens.append(Token(kind: .end, text: "", location: location, number: nil))
                    return tokens
                }
                let value = scalar.value
                if Self.isIdentifierStart(value) {
                    let start = index
                    advance()
                    while let next = current, Self.isIdentifierContinue(next.value) { advance() }
                    try append(Token(kind: .identifier, text: text(from: start), location: location, number: nil), to: &tokens)
                    continue
                }
                if Self.isDigit(value) || (value == 46 && Self.isDigit(peek(1)?.value ?? 0)) {
                    let start = index
                    try scanNumber()
                    let text = text(from: start)
                    guard let number = Double(text), number.isFinite else {
                        throw DSPScriptCompiler.failure(
                            "script.invalidNumber",
                            "Numeric literals must be finite.",
                            at: location
                        )
                    }
                    try append(Token(kind: .number, text: text, location: location, number: number), to: &tokens)
                    continue
                }

                let twoCharacter = peek(1).map { String(scalar) + String($0) } ?? String(scalar)
                if ["==", "!=", "<=", ">=", "&&", "||"].contains(twoCharacter) {
                    advance()
                    advance()
                    try append(Token(kind: .symbol, text: twoCharacter, location: location, number: nil), to: &tokens)
                    continue
                }
                if "(){}:;=,+-*/%^?!<>".unicodeScalars.contains(scalar) {
                    advance()
                    try append(Token(kind: .symbol, text: String(scalar), location: location, number: nil), to: &tokens)
                    continue
                }
                throw DSPScriptCompiler.failure(
                    "script.invalidCharacter",
                    "The source contains a character outside the DSP script language.",
                    at: location
                )
            }
        }

        private var current: UnicodeScalar? {
            scalars.indices.contains(index) ? scalars[index] : nil
        }

        private func peek(_ distance: Int) -> UnicodeScalar? {
            let target = index + distance
            return scalars.indices.contains(target) ? scalars[target] : nil
        }

        private mutating func append(_ token: Token, to tokens: inout [Token]) throws {
            guard tokens.count < DSPScriptCompiler.maximumTokenCount else {
                throw DSPScriptCompiler.failure(
                    "script.tokenBudgetExceeded",
                    "The script contains too many tokens.",
                    at: token.location
                )
            }
            tokens.append(token)
        }

        private mutating func skipTrivia() throws {
            while let scalar = current {
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    advance()
                    continue
                }
                guard scalar.value == 47 else { return }
                if peek(1)?.value == 47 {
                    advance()
                    advance()
                    while let next = current, next.value != 10, next.value != 13 { advance() }
                    continue
                }
                if peek(1)?.value == 42 {
                    let location = Location(line: line, column: column)
                    advance()
                    advance()
                    var closed = false
                    while current != nil {
                        if current?.value == 42, peek(1)?.value == 47 {
                            advance()
                            advance()
                            closed = true
                            break
                        }
                        advance()
                    }
                    guard closed else {
                        throw DSPScriptCompiler.failure("script.unterminatedComment", "A block comment is not closed.", at: location)
                    }
                    continue
                }
                return
            }
        }

        private mutating func scanNumber() throws {
            var sawDigit = false
            while let scalar = current, Self.isDigit(scalar.value) {
                sawDigit = true
                advance()
            }
            if current?.value == 46 {
                advance()
                while let scalar = current, Self.isDigit(scalar.value) {
                    sawDigit = true
                    advance()
                }
            }
            guard sawDigit else { return }
            if current?.value == 101 || current?.value == 69 {
                let exponentLocation = Location(line: line, column: column)
                advance()
                if current?.value == 43 || current?.value == 45 { advance() }
                let exponentStart = index
                while let scalar = current, Self.isDigit(scalar.value) { advance() }
                guard index > exponentStart else {
                    throw DSPScriptCompiler.failure("script.invalidNumber", "The exponent requires digits.", at: exponentLocation)
                }
            }
        }

        @discardableResult
        private mutating func advance() -> UnicodeScalar? {
            guard let scalar = current else { return nil }
            index += 1
            if scalar.value == 10 {
                line += 1
                column = 1
            } else if scalar.value != 13 {
                column += 1
            }
            return scalar
        }

        private func text(from start: Int) -> String {
            String(String.UnicodeScalarView(scalars[start..<index]))
        }

        private static func isDigit(_ value: UInt32) -> Bool { (48...57).contains(value) }

        private static func isIdentifierStart(_ value: UInt32) -> Bool {
            (65...90).contains(value) || (97...122).contains(value) || value == 95
        }

        private static func isIdentifierContinue(_ value: UInt32) -> Bool {
            isIdentifierStart(value) || isDigit(value)
        }
    }

    private struct ParameterDeclaration {
        let name: String
        let minimum: Double
        let maximum: Double
        let defaultValue: Double
        let location: Location
    }

    private struct StateDeclaration {
        let name: String
        let initialValue: Expression
        let location: Location
    }

    private struct LetDeclaration {
        let name: String
        let expression: Expression
        let location: Location
    }

    private enum Statement {
        case letDeclaration(LetDeclaration)
        case assignment(name: String, expression: Expression, location: Location)
    }

    private struct ScriptSyntax {
        var parameters = [ParameterDeclaration]()
        var latencyFrames = 0
        var states = [StateDeclaration]()
        var prepare = [LetDeclaration]()
        var process = [Statement]()
        var hasPrepare = false
        var hasProcess = false
    }

    private indirect enum Expression {
        case number(Double, Location)
        case variable(String, Location)
        case unary(String, Expression, Location)
        case binary(String, Expression, Expression, Location)
        case conditional(Expression, Expression, Expression, Location)
        case call(String, [Expression], Location)

        var depth: Int {
            switch self {
            case .number, .variable: 1
            case let .unary(_, value, _): 1 + value.depth
            case let .binary(_, left, right, _): 1 + max(left.depth, right.depth)
            case let .conditional(condition, whenTrue, whenFalse, _):
                1 + max(condition.depth, max(whenTrue.depth, whenFalse.depth))
            case let .call(_, arguments, _): 1 + (arguments.map(\.depth).max() ?? 0)
            }
        }

        var location: Location {
            switch self {
            case let .number(_, location), let .variable(_, location),
                 let .unary(_, _, location), let .binary(_, _, _, location),
                 let .conditional(_, _, _, location), let .call(_, _, location):
                location
            }
        }
    }

    private struct Parser {
        let tokens: [Token]
        var index = 0
        var nestedExpressionDepth = 0

        init(tokens: [Token]) { self.tokens = tokens }

        mutating func parse() throws -> ScriptSyntax {
            var result = ScriptSyntax()
            while current.kind != .end {
                switch current.text {
                case "param": result.parameters.append(try parseParameter())
                case "latency": result.latencyFrames = try parseLatency()
                case "state": result.states.append(try parseState())
                case "prepare":
                    guard !result.hasPrepare else { throw syntax("Only one prepare block is allowed.") }
                    result.hasPrepare = true
                    result.prepare = try parsePrepareBlock()
                case "process":
                    guard !result.hasProcess else { throw syntax("Only one process block is allowed.") }
                    result.hasProcess = true
                    result.process = try parseProcessBlock()
                case ";": index += 1
                default: throw syntax("Expected a parameter, state, latency declaration, or block.")
                }
            }
            guard result.hasProcess else {
                throw DSPScriptCompiler.failure(
                    "script.missingProcessBlock",
                    "The script requires a process block.",
                    at: current.location
                )
            }
            return result
        }

        private var current: Token { tokens[min(index, tokens.count - 1)] }

        private mutating func parseParameter() throws -> ParameterDeclaration {
            let location = current.location
            index += 1
            let name = try identifier()
            if consume(":") { try expectIdentifier("float") }
            try expect("(")
            let minimum = try signedNumber()
            try expect(",")
            let maximum = try signedNumber()
            try expect(")")
            try expect("=")
            let defaultValue = try signedNumber()
            try expect(";")
            return ParameterDeclaration(
                name: name,
                minimum: minimum,
                maximum: maximum,
                defaultValue: defaultValue,
                location: location
            )
        }

        private mutating func parseLatency() throws -> Int {
            let token = current
            index += 1
            guard current.kind == .number,
                  let number = current.number,
                  number.rounded(.towardZero) == number,
                  number >= 0,
                  number <= Double(DSPScriptCompiler.maximumLatencyFrames) else {
                throw DSPScriptCompiler.failure(
                    "script.invalidLatency",
                    "Declared latency must be an integer from 0 through 2048 frames.",
                    at: current.location
                )
            }
            index += 1
            try expect(";")
            _ = token
            return Int(number)
        }

        private mutating func parseState() throws -> StateDeclaration {
            let location = current.location
            index += 1
            let name = try identifier()
            if consume(":") { try expectIdentifier("float") }
            try expect("=")
            let value = try expression()
            try expect(";")
            return StateDeclaration(name: name, initialValue: value, location: location)
        }

        private mutating func parsePrepareBlock() throws -> [LetDeclaration] {
            index += 1
            try expect("{")
            var declarations = [LetDeclaration]()
            while !consume("}") {
                guard current.kind != .end else { throw syntax("The prepare block is not closed.") }
                let location = current.location
                try expectIdentifier("let")
                let name = try identifier()
                try expect("=")
                let value = try expression()
                try expect(";")
                declarations.append(LetDeclaration(name: name, expression: value, location: location))
            }
            _ = consume(";")
            return declarations
        }

        private mutating func parseProcessBlock() throws -> [Statement] {
            index += 1
            try expect("{")
            var statements = [Statement]()
            while !consume("}") {
                guard current.kind != .end else { throw syntax("The process block is not closed.") }
                let location = current.location
                if consume("let") {
                    let name = try identifier()
                    try expect("=")
                    let value = try expression()
                    try expect(";")
                    statements.append(.letDeclaration(LetDeclaration(
                        name: name,
                        expression: value,
                        location: location
                    )))
                } else {
                    let name = try identifier()
                    try expect("=")
                    let value = try expression()
                    try expect(";")
                    statements.append(.assignment(name: name, expression: value, location: location))
                }
            }
            _ = consume(";")
            return statements
        }

        private mutating func expression() throws -> Expression {
            try enterExpression(at: current.location)
            defer { nestedExpressionDepth -= 1 }
            var condition = try binaryExpression(minimumPrecedence: 1)
            if consume("?") {
                let location = condition.location
                let whenTrue = try expression()
                try expect(":")
                let whenFalse = try expression()
                condition = try bounded(.conditional(condition, whenTrue, whenFalse, location))
            }
            return condition
        }

        private mutating func binaryExpression(minimumPrecedence: Int) throws -> Expression {
            try enterExpression(at: current.location)
            defer { nestedExpressionDepth -= 1 }
            var left = try unaryExpression()
            while let precedence = Self.precedence(of: current.text), precedence >= minimumPrecedence {
                let operation = current.text
                let location = current.location
                index += 1
                let nextMinimum = operation == "^" ? precedence : precedence + 1
                let right = try binaryExpression(minimumPrecedence: nextMinimum)
                left = try bounded(.binary(operation, left, right, location))
            }
            return left
        }

        private mutating func unaryExpression() throws -> Expression {
            var prefix = [(String, Location)]()
            while ["+", "-", "!"].contains(current.text) {
                guard prefix.count < DSPScriptCompiler.maximumExpressionDepth else {
                    throw syntax("Expression nesting exceeds the supported bound.")
                }
                prefix.append((current.text, current.location))
                index += 1
            }
            var result = try primaryExpression()
            for (operation, location) in prefix.reversed() where operation != "+" {
                result = try bounded(.unary(operation, result, location))
            }
            return result
        }

        private mutating func primaryExpression() throws -> Expression {
            if current.kind == .number, let number = current.number {
                let token = current
                index += 1
                return .number(number, token.location)
            }
            if current.kind == .identifier {
                let token = current
                index += 1
                guard consume("(") else { return .variable(token.text, token.location) }
                try enterExpression(at: token.location)
                defer { nestedExpressionDepth -= 1 }
                var arguments = [Expression]()
                if !consume(")") {
                    repeat { arguments.append(try expression()) } while consume(",")
                    try expect(")")
                }
                return try bounded(.call(token.text, arguments, token.location))
            }
            if consume("(") {
                try enterExpression(at: current.location)
                defer { nestedExpressionDepth -= 1 }
                let result = try expression()
                try expect(")")
                return result
            }
            throw syntax("Expected a number, variable, function call, or parenthesized expression.")
        }

        private mutating func signedNumber() throws -> Double {
            var sign = 1.0
            if consume("-") { sign = -1 }
            else { _ = consume("+") }
            guard current.kind == .number, let number = current.number else {
                throw syntax("Expected a numeric literal.")
            }
            index += 1
            return sign * number
        }

        private func bounded(_ expression: Expression) throws -> Expression {
            guard expression.depth <= DSPScriptCompiler.maximumExpressionDepth else {
                throw DSPScriptCompiler.failure("script.expressionBudgetExceeded",
                    "Expression depth exceeds the supported bound.", at: expression.location)
            }
            return expression
        }

        private mutating func identifier() throws -> String {
            guard current.kind == .identifier else { throw syntax("Expected an identifier.") }
            let result = current.text
            index += 1
            return result
        }

        private mutating func expectIdentifier(_ expected: String) throws {
            guard current.kind == .identifier, current.text == expected else {
                throw syntax("Expected '\(expected)'.")
            }
            index += 1
        }

        private mutating func expect(_ symbol: String) throws {
            guard consume(symbol) else { throw syntax("Expected '\(symbol)'.") }
        }

        @discardableResult
        private mutating func consume(_ text: String) -> Bool {
            guard current.text == text else { return false }
            index += 1
            return true
        }

        private mutating func enterExpression(at location: Location) throws {
            nestedExpressionDepth += 1
            guard nestedExpressionDepth <= DSPScriptCompiler.maximumExpressionDepth else {
                throw DSPScriptCompiler.failure(
                    "script.expressionDepthExceeded",
                    "Expression nesting exceeds the supported bound.",
                    at: location
                )
            }
        }

        private func syntax(_ message: String) -> DSPScriptCompilationError {
            DSPScriptCompiler.failure("script.syntax", message, at: current.location)
        }

        private static func precedence(of operation: String) -> Int? {
            switch operation {
            case "<", "<=", ">", ">=", "==", "!=": return 1
            case "+", "-": return 2
            case "*", "/", "%": return 3
            case "^": return 4
            default: return nil
            }
        }
    }

    private enum StaticValue {
        case constant(Double)
        case formatDependent
        case dynamic

        var isCompileTimeValue: Bool {
            switch self {
            case .constant, .formatDependent: return true
            case .dynamic: return false
            }
        }
    }

    /// Format-independent front-end validation used while the player has no
    /// decoded source format yet. It deliberately leaves channel/rate budgets
    /// and format-dependent constants for the later strict compile step.
    static func validateSource(
        source: String,
        languageVersion: Int = 1,
        parameterValues: [String: Double] = [:]
    ) throws -> [DSPScriptParameter] {
        guard languageVersion == 1 else {
            throw failure("script.unsupportedLanguageVersion", "Only DSP script language version 1 is supported.", at: Location(line: 1, column: 1))
        }
        guard source.utf8.count <= maximumSourceBytes else {
            throw failure("script.sourceBudgetExceeded", "The script source exceeds the 64 KiB limit.", at: Location(line: 1, column: 1))
        }
        var lexer = Lexer(source: source)
        let tokens = try lexer.lex()
        var parser = Parser(tokens: tokens)
        let syntax = try parser.parse()
        guard syntax.parameters.count <= maximumParameterCount else {
            throw failure("script.parameterBudgetExceeded", "A script may declare at most 32 parameters.", at: syntax.parameters[maximumParameterCount].location)
        }
        guard (0...maximumLatencyFrames).contains(syntax.latencyFrames) else {
            throw failure("script.latencyBudgetExceeded", "Declared latency must be between 0 and 2048 frames.", at: Location(line: 1, column: 1))
        }

        var reflected = [DSPScriptParameter]()
        var symbols = [String: StaticValue](minimumCapacity: syntax.parameters.count + syntax.prepare.count + syntax.states.count + 8)
        var names = Set<String>()
        for parameter in syntax.parameters {
            guard names.insert(parameter.name).inserted else {
                throw failure("script.duplicateParameter", "Parameter names must be unique.", at: parameter.location, fieldPath: "parameters.\(parameter.name)")
            }
            guard !isReservedName(parameter.name) else {
                throw failure("script.reservedParameterName", "Parameter names cannot replace built-in names.", at: parameter.location, fieldPath: "parameters.\(parameter.name)")
            }
            guard parameter.minimum.isFinite, parameter.maximum.isFinite,
                  parameter.defaultValue.isFinite, parameter.minimum < parameter.maximum,
                  parameter.defaultValue >= parameter.minimum, parameter.defaultValue <= parameter.maximum else {
                throw failure("script.invalidParameterRange", "Parameter bounds must be finite and ordered, and the default must be in range.", at: parameter.location, fieldPath: "parameters.\(parameter.name)")
            }
            let value = parameterValues[parameter.name] ?? parameter.defaultValue
            guard value.isFinite, value >= parameter.minimum, value <= parameter.maximum else {
                throw failure("script.parameterOutOfRange", "The supplied parameter value is outside its declared range.", at: parameter.location, fieldPath: "parameters.\(parameter.name)")
            }
            symbols[parameter.name] = .constant(value)
            reflected.append(DSPScriptParameter(name: parameter.name, minValue: parameter.minimum, maxValue: parameter.maximum, defaultValue: parameter.defaultValue))
        }
        let unknown = Set(parameterValues.keys).subtracting(names)
        if let name = unknown.sorted().first {
            throw failure("script.unknownParameter", "A parameter value was supplied for an undeclared parameter.", at: Location(line: 1, column: 1), fieldPath: "parameters.\(name)")
        }
        symbols["pi"] = .constant(Double.pi)
        symbols["e"] = .constant(2.718_281_828_459_045)
        symbols["channels"] = .formatDependent
        symbols["sampleRate"] = .formatDependent

        for declaration in syntax.prepare {
            guard names.insert(declaration.name).inserted, !isReservedName(declaration.name) else {
                throw failure("script.duplicateDeclaration", "A prepare variable cannot replace an existing or built-in name.", at: declaration.location, fieldPath: "prepare.\(declaration.name)")
            }
            let value = try validateExpression(declaration.expression, symbols: symbols, requiresConstant: true)
            symbols[declaration.name] = value
        }

        var stateNames = Set<String>()
        for declaration in syntax.states {
            guard stateNames.insert(declaration.name).inserted,
                  names.insert(declaration.name).inserted,
                  !isReservedName(declaration.name) else {
                throw failure("script.duplicateDeclaration", "State names must be unique and cannot replace an existing or built-in name.", at: declaration.location, fieldPath: "state.\(declaration.name)")
            }
            _ = try validateExpression(declaration.initialValue, symbols: symbols, requiresConstant: true)
            symbols[declaration.name] = .dynamic
        }

        var processNames = names
        var outputAssignmentCount = 0
        for statement in syntax.process {
            switch statement {
            case let .letDeclaration(declaration):
                guard processNames.insert(declaration.name).inserted,
                      !isReservedName(declaration.name) else {
                    throw failure("script.duplicateDeclaration", "A process variable cannot replace another name.", at: declaration.location, fieldPath: "process.\(declaration.name)")
                }
                symbols[declaration.name] = try validateExpression(declaration.expression, symbols: symbols, requiresConstant: false)
            case let .assignment(name, expression, location):
                guard name == "output" || stateNames.contains(name) else {
                    throw failure("script.unknownAssignmentTarget", "Only output or a declared state variable can be assigned.", at: location, fieldPath: "process.\(name)")
                }
                _ = try validateExpression(expression, symbols: symbols, requiresConstant: false)
                if name == "output" { outputAssignmentCount += 1 }
            }
        }
        guard outputAssignmentCount > 0 else {
            throw failure("script.missingOutputAssignment", "The process block must assign output at least once.", at: syntax.process.first.map { location(of: $0) } ?? Location(line: 1, column: 1))
        }
        return reflected
    }

    private static func validateExpression(
        _ expression: Expression,
        symbols: [String: StaticValue],
        requiresConstant: Bool
    ) throws -> StaticValue {
        let value: StaticValue
        switch expression {
        case let .number(number, _):
            value = .constant(number)
        case let .variable(name, location):
            if let symbol = symbols[name] {
                value = symbol
            } else if ["input", "output", "channel"].contains(name) {
                value = .dynamic
            } else {
                throw failure("script.unknownName", "The expression refers to an undeclared name.", at: location, fieldPath: "source.\(name)")
            }
        case let .unary(operation, operand, location):
            let operandValue = try validateExpression(operand, symbols: symbols, requiresConstant: requiresConstant)
            value = try applyStaticUnary(operation, operand: operandValue, at: location, requiresConstant: requiresConstant)
        case let .binary(operation, left, right, location):
            let leftValue = try validateExpression(left, symbols: symbols, requiresConstant: requiresConstant)
            let rightValue = try validateExpression(right, symbols: symbols, requiresConstant: requiresConstant)
            value = try applyStaticBinary(operation, left: leftValue, right: rightValue, at: location, requiresConstant: requiresConstant)
        case let .conditional(condition, trueExpression, falseExpression, location):
            let conditionValue = try validateExpression(condition, symbols: symbols, requiresConstant: requiresConstant)
            switch conditionValue {
            case let .constant(selector):
                let chosen = selector != 0 ? trueExpression : falseExpression
                let unchosen = selector != 0 ? falseExpression : trueExpression
                _ = try validateExpression(unchosen, symbols: symbols, requiresConstant: false)
                value = try validateExpression(chosen, symbols: symbols, requiresConstant: requiresConstant)
            case .formatDependent:
                let trueValue = try validateExpression(trueExpression, symbols: symbols, requiresConstant: requiresConstant)
                let falseValue = try validateExpression(falseExpression, symbols: symbols, requiresConstant: requiresConstant)
                _ = combine(trueValue, falseValue)
                value = .formatDependent
            case .dynamic:
                let trueValue = try validateExpression(trueExpression, symbols: symbols, requiresConstant: requiresConstant)
                let falseValue = try validateExpression(falseExpression, symbols: symbols, requiresConstant: requiresConstant)
                _ = combine(trueValue, falseValue)
                value = .dynamic
            }
            _ = location
        case let .call(name, arguments, location):
            value = try validateCall(name, arguments: arguments, at: location, symbols: symbols, requiresConstant: requiresConstant)
        }
        if requiresConstant, !value.isCompileTimeValue {
            throw failure("script.nonConstantExpression", "This value must be known during prepare.", at: expression.location)
        }
        return value
    }

    private static func validateCall(
        _ name: String,
        arguments: [Expression],
        at location: Location,
        symbols: [String: StaticValue],
        requiresConstant: Bool
    ) throws -> StaticValue {
        let arity: Int
        switch name {
        case "channel", "channels", "sampleRate": arity = 0
        case "abs", "sqrt", "sin", "cos", "tanh", "exp", "log", "dbToGain": arity = 1
        case "min", "max", "pow", "delay", "smooth": arity = 2
        case "inputAt": arity = 1
        case "mix": arity = 3
        case "clamp": arity = 3
        case "biquad": arity = 6
        default: throw failure("script.unknownFunction", "The function is not part of DSP script language version 1.", at: location, fieldPath: "source.\(name)")
        }
        if name == "inputAt", arguments.count == 1 { // inputAt has one static index.
            let index = try validateExpression(arguments[0], symbols: symbols, requiresConstant: false)
            switch index {
            case let .constant(value):
                guard value.isFinite, value.rounded(.towardZero) == value, value >= 0, value < Double(maximumChannelCount) else {
                    throw failure("script.invalidInputChannel", "inputAt requires an integer channel index from 0 through 31.", at: location)
                }
            case .formatDependent: break
            case .dynamic: throw failure("script.invalidInputChannel", "inputAt requires a compile-time channel index.", at: location)
            }
            if requiresConstant { throw failure("script.nonConstantExpression", "inputAt is only available in the process block.", at: location) }
            return .dynamic
        }
        guard arguments.count == arity else {
            throw failure("script.functionArity", "\(name) expects \(arity) argument(s).", at: location)
        }
        if ["biquad", "delay", "smooth"].contains(name), requiresConstant {
            throw failure("script.invalidPrepareFunction", "Stateful audio functions are only available in the process block.", at: location)
        }
        let values = try arguments.map { try validateExpression($0, symbols: symbols, requiresConstant: false) }
        if name == "delay" {
            guard values[1].isCompileTimeValue else { throw failure("script.invalidDelay", "delay requires a fixed frame count.", at: location) }
            if case let .constant(frames) = values[1], !isIntegerInRange(frames, 0...65_536) {
                throw failure("script.invalidDelay", "delay requires an integer constant from 0 through 65536 frames.", at: location)
            }
            return .dynamic
        }
        if name == "smooth" {
            guard values[1].isCompileTimeValue else { throw failure("script.invalidSmoothCoefficient", "smooth requires a fixed coefficient.", at: location) }
            if case let .constant(coefficient) = values[1], !(0...1).contains(coefficient) {
                throw failure("script.invalidSmoothCoefficient", "smooth coefficient must be between 0 and 1.", at: location)
            }
            return .dynamic
        }
        if name == "biquad" {
            guard values.dropFirst().allSatisfy(\.isCompileTimeValue) else {
                throw failure("script.invalidBiquad", "Biquad coefficients must be fixed at compile time.", at: location)
            }
            let coefficients = values.dropFirst().compactMap { value -> Double? in
                if case let .constant(number) = value { return number }
                return nil
            }
            if coefficients.count == 5 {
                let a1 = coefficients[3]
                let a2 = coefficients[4]
                guard coefficients.allSatisfy(\.isFinite), abs(a2) < 1,
                      1 + a1 + a2 > 0, 1 - a1 + a2 > 0 else {
                    throw failure("script.invalidBiquad", "Biquad coefficients must have a stable denominator.", at: location)
                }
            }
            return .dynamic
        }
        if ["channel", "channels", "sampleRate"].contains(name) {
            return name == "channel" ? .dynamic : .formatDependent
        }
        if values.allSatisfy({ if case .constant = $0 { true } else { false } }) {
            let constants = values.compactMap(constantValue)
            guard constants.count == values.count else { return .dynamic }
            if let result = pureFunction(name, arguments: constants), result.isFinite {
                return .constant(result)
            }
            if requiresConstant {
                throw failure("script.nonFiniteConstant", "Prepare expressions must produce finite values.", at: location)
            }
            return .dynamic
        }
        return combine(values)
    }

    private static func combine(_ values: [StaticValue]) -> StaticValue {
        if values.contains(where: { if case .dynamic = $0 { true } else { false } }) { return .dynamic }
        if values.contains(where: { if case .formatDependent = $0 { true } else { false } }) { return .formatDependent }
        return .constant(0)
    }

    private static func combine(_ left: StaticValue, _ right: StaticValue) -> StaticValue {
        combine([left, right])
    }

    private static func constantValue(_ value: StaticValue) -> Double? {
        if case let .constant(number) = value { return number }
        return nil
    }

    private static func applyStaticUnary(
        _ operation: String,
        operand: StaticValue,
        at location: Location,
        requiresConstant: Bool
    ) throws -> StaticValue {
        guard case let .constant(value) = operand else { return operand }
        let result: Double
        switch operation {
        case "+": result = value
        case "-": result = -value
        case "!": result = value == 0 ? 1 : 0
        default: throw failure("script.unsupportedOperator", "The unary operator is not supported.", at: location)
        }
        if result.isFinite { return .constant(result) }
        if requiresConstant { throw failure("script.nonFiniteConstant", "Prepare expressions must produce finite values.", at: location) }
        return .dynamic
    }

    private static func applyStaticBinary(
        _ operation: String,
        left: StaticValue,
        right: StaticValue,
        at location: Location,
        requiresConstant: Bool
    ) throws -> StaticValue {
        guard case let .constant(lhs) = left, case let .constant(rhs) = right else {
            return combine(left, right)
        }
        let result: Double
        switch operation {
        case "+": result = lhs + rhs
        case "-": result = lhs - rhs
        case "*": result = lhs * rhs
        case "/":
            guard rhs != 0 else {
                if requiresConstant { throw failure("script.constantDivisionByZero", "A constant expression divides by zero.", at: location) }
                return .dynamic
            }
            result = lhs / rhs
        case "%":
            guard rhs != 0 else {
                if requiresConstant { throw failure("script.constantDivisionByZero", "A constant expression divides by zero.", at: location) }
                return .dynamic
            }
            result = lhs.truncatingRemainder(dividingBy: rhs)
        case "^": result = pow(lhs, rhs)
        case "<": result = lhs < rhs ? 1 : 0
        case "<=": result = lhs <= rhs ? 1 : 0
        case ">": result = lhs > rhs ? 1 : 0
        case ">=": result = lhs >= rhs ? 1 : 0
        case "==": result = lhs == rhs ? 1 : 0
        case "!=": result = lhs != rhs ? 1 : 0
        default: throw failure("script.unsupportedOperator", "The binary operator is not supported.", at: location)
        }
        if result.isFinite { return .constant(result) }
        if requiresConstant { throw failure("script.nonFiniteConstant", "Prepare expressions must produce finite values.", at: location) }
        return .dynamic
    }

    private static func pureFunction(_ name: String, arguments: [Double]) -> Double? {
        switch name {
        case "abs" where arguments.count == 1: return abs(arguments[0])
        case "sqrt" where arguments.count == 1 && arguments[0] >= 0: return sqrt(arguments[0])
        case "sin" where arguments.count == 1: return sin(arguments[0])
        case "cos" where arguments.count == 1: return cos(arguments[0])
        case "tanh" where arguments.count == 1: return tanh(arguments[0])
        case "exp" where arguments.count == 1: return exp(arguments[0])
        case "log" where arguments.count == 1 && arguments[0] > 0: return log(arguments[0])
        case "dbToGain" where arguments.count == 1: return pow(10, arguments[0] / 20)
        case "min" where arguments.count == 2: return min(arguments[0], arguments[1])
        case "max" where arguments.count == 2: return max(arguments[0], arguments[1])
        case "pow" where arguments.count == 2: return pow(arguments[0], arguments[1])
        case "clamp" where arguments.count == 3: return min(max(arguments[0], arguments[1]), arguments[2])
        case "mix" where arguments.count == 3: return arguments[0] + (arguments[1] - arguments[0]) * arguments[2]
        default: return nil
        }
    }

    private static func isIntegerInRange(_ value: Double, _ range: ClosedRange<Double>) -> Bool {
        value.isFinite && value.rounded(.towardZero) == value && range.contains(value)
    }

    static func compile(
        source: String,
        languageVersion: Int = 1,
        parameterValues: [String: Double] = [:],
        format: DSPAudioFormat
    ) throws -> DSPScriptProgram {
        guard languageVersion == 1 else {
            throw failure(
                "script.unsupportedLanguageVersion",
                "Only DSP script language version 1 is supported.",
                at: Location(line: 1, column: 1)
            )
        }
        guard source.utf8.count <= maximumSourceBytes else {
            throw failure(
                "script.sourceBudgetExceeded",
                "The script source exceeds the 64 KiB limit.",
                at: Location(line: 1, column: 1)
            )
        }
        guard format.sampleRate.isFinite,
              format.sampleRate >= 8_000,
              format.sampleRate <= maximumSampleRate,
              (1...maximumChannelCount).contains(format.channelCount) else {
            throw failure(
                "script.unsupportedFormat",
                "The script requires 1–32 channels and a sample rate from 8 kHz through 768 kHz.",
                at: Location(line: 1, column: 1),
                fieldPath: "format"
            )
        }

        let sourceHash = Self.sha256(source)
        let formatKey = Self.formatKey(format)
        let cacheBaseKey = "\(sourceHash)|\(languageVersion)|\(formatKey)"
        if let cached = DSPScriptProgramCache.shared.lookup(
            baseKey: cacheBaseKey,
            suppliedValues: parameterValues
        ) {
            return cached
        }

        var lexer = Lexer(source: source)
        let tokens = try lexer.lex()
        var parser = Parser(tokens: tokens)
        let syntax = try parser.parse()

        guard syntax.parameters.count <= maximumParameterCount else {
            throw failure(
                "script.parameterBudgetExceeded",
                "A script may declare at most 32 parameters.",
                at: syntax.parameters.dropFirst(maximumParameterCount).first?.location
                    ?? Location(line: 1, column: 1)
            )
        }
        guard (0...maximumLatencyFrames).contains(syntax.latencyFrames) else {
            throw failure(
                "script.latencyBudgetExceeded",
                "Declared latency must be between 0 and 2048 frames.",
                at: Location(line: 1, column: 1)
            )
        }

        var parameterNames = Set<String>()
        var effectiveValues = [String: Double]()
        var reflectedParameters = [DSPScriptParameter]()
        reflectedParameters.reserveCapacity(syntax.parameters.count)
        for declaration in syntax.parameters {
            guard parameterNames.insert(declaration.name).inserted else {
                throw failure(
                    "script.duplicateParameter",
                    "Parameter names must be unique.",
                    at: declaration.location,
                    fieldPath: "parameters.\(declaration.name)"
                )
            }
            guard !Self.isReservedName(declaration.name) else {
                throw failure(
                    "script.reservedParameterName",
                    "Parameter names cannot replace built-in names.",
                    at: declaration.location,
                    fieldPath: "parameters.\(declaration.name)"
                )
            }
            guard declaration.minimum.isFinite,
                  declaration.maximum.isFinite,
                  declaration.defaultValue.isFinite,
                  declaration.minimum < declaration.maximum,
                  declaration.defaultValue >= declaration.minimum,
                  declaration.defaultValue <= declaration.maximum else {
                throw failure(
                    "script.invalidParameterRange",
                    "Parameter bounds must be finite and ordered, and the default must be in range.",
                    at: declaration.location,
                    fieldPath: "parameters.\(declaration.name)"
                )
            }
            let value = parameterValues[declaration.name] ?? declaration.defaultValue
            guard value.isFinite,
                  value >= declaration.minimum,
                  value <= declaration.maximum else {
                throw failure(
                    "script.parameterOutOfRange",
                    "The supplied parameter value is outside its declared range.",
                    at: declaration.location,
                    fieldPath: "parameters.\(declaration.name)"
                )
            }
            effectiveValues[declaration.name] = value
            reflectedParameters.append(DSPScriptParameter(
                name: declaration.name,
                minValue: declaration.minimum,
                maxValue: declaration.maximum,
                defaultValue: declaration.defaultValue
            ))
        }
        let unknownParameterNames = Set(parameterValues.keys).subtracting(parameterNames)
        guard unknownParameterNames.isEmpty else {
            let unknown = unknownParameterNames.sorted().first ?? ""
            throw failure(
                "script.unknownParameter",
                "A parameter value was supplied for an undeclared parameter.",
                at: Location(line: 1, column: 1),
                fieldPath: "parameters.\(unknown)"
            )
        }

        var constants = effectiveValues
        constants["channels"] = Double(format.channelCount)
        constants["sampleRate"] = format.sampleRate
        constants["pi"] = Double.pi
        constants["e"] = 2.718_281_828_459_045
        var constantNames = Set(constants.keys)
        for declaration in syntax.prepare {
            guard !constantNames.contains(declaration.name),
                  !Self.isReservedName(declaration.name) else {
                throw failure(
                    "script.duplicateDeclaration",
                    "A prepare variable cannot replace a parameter, state, or built-in name.",
                    at: declaration.location,
                    fieldPath: "prepare.\(declaration.name)"
                )
            }
            let value = try evaluateConstant(
                declaration.expression,
                constants: constants,
                format: format
            )
            constants[declaration.name] = value
            constantNames.insert(declaration.name)
        }

        var stateNames = Set<String>()
        var stateSlots = [DSPScriptStateSlot]()
        var stateInitialValues = [Double]()
        var stateStride = 0
        for declaration in syntax.states {
            guard stateNames.insert(declaration.name).inserted,
                  !constantNames.contains(declaration.name),
                  !Self.isReservedName(declaration.name) else {
                throw failure(
                    "script.duplicateDeclaration",
                    "State names must be unique and cannot replace a parameter, prepare variable, or built-in.",
                    at: declaration.location,
                    fieldPath: "state.\(declaration.name)"
                )
            }
            let initialValue = try evaluateConstant(
                declaration.initialValue,
                constants: constants,
                format: format
            )
            let slot = DSPScriptStateSlot(
                name: declaration.name,
                kind: .variable,
                offset: stateStride,
                length: 1,
                initialValue: initialValue,
                delayOrdinal: nil
            )
            stateSlots.append(slot)
            stateInitialValues.append(initialValue)
            stateStride += 1
        }

        var generator = Generator(
            constants: constants,
            channelCount: format.channelCount,
            stateNames: Dictionary(uniqueKeysWithValues: stateSlots.enumerated().compactMap { index, slot in
                slot.name.map { ($0, index) }
            }),
            stateSlots: stateSlots,
            stateStride: stateStride,
            stateInitialValues: stateInitialValues
        )
        for statement in syntax.process {
            try generator.compile(statement: statement, format: format)
        }
        guard generator.outputAssignmentCount > 0 else {
            throw failure(
                "script.missingOutputAssignment",
                "The process block must assign output at least once.",
                at: syntax.process.first.map { Self.location(of: $0) } ?? Location(line: 1, column: 1)
            )
        }
        guard generator.instructions.count <= maximumInstructionCount else {
            throw failure(
                "script.instructionBudgetExceeded",
                "The process block exceeds the fixed instruction budget.",
                at: syntax.process.first.map { Self.location(of: $0) } ?? Location(line: 1, column: 1)
            )
        }

        let weightedOperations = Self.worstCaseOperationsPerFrame(generator.instructions)
        guard weightedOperations > 0 else {
            throw failure(
                "script.emptyProcessBlock",
                "The process block contains no executable operations.",
                at: Location(line: 1, column: 1)
            )
        }
        let weightedOperationsPerSecond = Double(weightedOperations)
            * format.sampleRate * Double(format.channelCount)
        guard weightedOperationsPerSecond.isFinite,
              weightedOperationsPerSecond <= maximumWeightedOperationsPerSecond else {
            throw failure(
                "script.operationBudgetExceeded",
                "The estimated all-channel cost exceeds 24 million weighted operations per second.",
                at: Location(line: 1, column: 1),
                fieldPath: "format"
            )
        }

        let runtimeStateBytes = Self.runtimeStateBytes(
            channelCount: format.channelCount,
            stateStride: generator.stateStride,
            registerCount: generator.registerCount,
            delaySlotCount: generator.delaySlotCount,
            latencyFrames: syntax.latencyFrames
        )
        guard runtimeStateBytes <= maximumStateBytes else {
            throw failure(
                "script.stateBudgetExceeded",
                "The script's format-bound runtime state exceeds 4 MiB.",
                at: Location(line: 1, column: 1),
                fieldPath: "state"
            )
        }

        let program = DSPScriptProgram(
            sourceHash: sourceHash,
            languageVersion: languageVersion,
            parameters: reflectedParameters,
            parameterValues: effectiveValues,
            format: format,
            latencyFrames: syntax.latencyFrames,
            stateBytes: runtimeStateBytes,
            weightedOperationsPerFrame: weightedOperations,
            registerCount: generator.registerCount,
            stateStride: generator.stateStride,
            delaySlotCount: generator.delaySlotCount,
            stateSlots: generator.stateSlots,
            instructions: generator.instructions,
            stateInitializerValues: generator.stateInitialValues
        )
        let valueKey = Self.parameterKey(effectiveValues)
        DSPScriptProgramCache.shared.insert(
            program,
            baseKey: cacheBaseKey,
            valueKey: valueKey,
            artifactBytes: Self.estimatedArtifactBytes(program)
        )
        return program
    }

    private struct Generator {
        private let constants: [String: Double]
        private let channelCount: Int
        private var localRegisters: [String: Int] = [:]
        private var localConstants: [String: Double] = [:]
        private var declaredNames: Set<String>
        private var stateNames: [String: Int]
        private(set) var stateSlots: [DSPScriptStateSlot]
        private(set) var stateInitialValues: [Double]
        private(set) var stateStride: Int
        private(set) var delaySlotCount = 0
        private(set) var registerCount = 0
        private(set) var instructions = [DSPScriptInstruction]()
        private(set) var outputAssignmentCount = 0

        init(
            constants: [String: Double],
            channelCount: Int,
            stateNames: [String: Int],
            stateSlots: [DSPScriptStateSlot],
            stateStride: Int,
            stateInitialValues: [Double]
        ) {
            self.constants = constants
            self.channelCount = channelCount
            self.stateNames = stateNames
            self.stateSlots = stateSlots
            self.stateStride = stateStride
            self.stateInitialValues = stateInitialValues
            declaredNames = Set(constants.keys).union(stateNames.keys)
        }

        mutating func compile(statement: Statement, format: DSPAudioFormat) throws {
            switch statement {
            case let .letDeclaration(declaration):
                guard !declaredNames.contains(declaration.name),
                      !DSPScriptCompiler.isReservedName(declaration.name) else {
                    throw DSPScriptCompiler.failure(
                        "script.duplicateDeclaration",
                        "A process variable cannot replace another name.",
                        at: declaration.location,
                        fieldPath: "process.\(declaration.name)"
                    )
                }
                if let value = try? DSPScriptCompiler.evaluateConstant(
                    declaration.expression,
                    constants: constantsInScope,
                    format: format
                ) {
                    localConstants[declaration.name] = value
                }
                let value = try compile(expression: declaration.expression, format: format)
                localRegisters[declaration.name] = value
                declaredNames.insert(declaration.name)
            case let .assignment(name, expression, location):
                let value = try compile(expression: expression, format: format)
                if name == "output" {
                    emit(.output(source: value), at: location, weight: 1)
                    outputAssignmentCount += 1
                } else if let slot = stateNames[name] {
                    emit(.storeState(slot: slot, source: value), at: location, weight: 1)
                } else {
                    throw DSPScriptCompiler.failure(
                        "script.unknownAssignmentTarget",
                        "Only output or a declared state variable can be assigned.",
                        at: location,
                        fieldPath: "process.\(name)"
                    )
                }
            }
        }

        private mutating func compile(expression: Expression, format: DSPAudioFormat) throws -> Int {
            switch expression {
            case let .number(value, location):
                let destination = register()
                emit(.constant(destination: destination, value: value), at: location, weight: 0)
                return destination
            case let .variable(name, location):
                if let value = localRegisters[name] { return value }
                if let slot = stateNames[name] {
                    let destination = register()
                    emit(.loadState(destination: destination, slot: slot), at: location, weight: 1)
                    return destination
                }
                if name == "input" {
                    let destination = register()
                    emit(.input(destination: destination), at: location, weight: 1)
                    return destination
                }
                if name == "output" {
                    let destination = register()
                    emit(.outputValue(destination: destination), at: location, weight: 1)
                    return destination
                }
                if name == "channel" {
                    let destination = register()
                    emit(.channel(destination: destination), at: location, weight: 1)
                    return destination
                }
                if name == "channels" {
                    let destination = register()
                    emit(.channels(destination: destination), at: location, weight: 0)
                    return destination
                }
                if name == "sampleRate" {
                    let destination = register()
                    emit(.sampleRate(destination: destination), at: location, weight: 0)
                    return destination
                }
                if let value = constants[name] {
                    let destination = register()
                    emit(.constant(destination: destination, value: value), at: location, weight: 0)
                    return destination
                }
                throw DSPScriptCompiler.failure(
                    "script.unknownName",
                    "The expression refers to an undeclared name.",
                    at: location,
                    fieldPath: "process.\(name)"
                )
            case let .unary(operation, operand, location):
                let source = try compile(expression: operand, format: format)
                let destination = register()
                let opcode: DSPScriptUnaryOperation
                switch operation {
                case "-": opcode = .negate
                case "!": opcode = .logicalNot
                default:
                    throw DSPScriptCompiler.failure(
                        "script.unsupportedOperator",
                        "The unary operator is not supported.",
                        at: location
                    )
                }
                emit(.unary(destination: destination, operation: opcode, source: source), at: location, weight: 1)
                return destination
            case let .binary(operation, leftExpression, rightExpression, location):
                let left = try compile(expression: leftExpression, format: format)
                let right = try compile(expression: rightExpression, format: format)
                let destination = register()
                if let comparison = comparisonOperation(operation) {
                    emit(.compare(destination: destination, operation: comparison, left: left, right: right), at: location, weight: 1)
                    return destination
                }
                guard let binary = binaryOperation(operation) else {
                    throw DSPScriptCompiler.failure(
                        "script.unsupportedOperator",
                        "The binary operator is not supported.",
                        at: location
                    )
                }
                emit(.binary(destination: destination, operation: binary, left: left, right: right), at: location, weight: operation == "/" || operation == "%" ? 4 : operation == "^" ? 8 : 1)
                return destination
            case let .conditional(conditionExpression, trueExpression, falseExpression, location):
                // Forward-only control flow makes ternaries lazy: errors and stateful
                // calls in the branch that is not selected do not run.
                let condition = try compile(expression: conditionExpression, format: format)
                let destination = register()
                let falseJump = emit(.jumpIfFalse(condition: condition, target: 0), at: location, weight: 1)
                let whenTrue = try compile(expression: trueExpression, format: format)
                emit(.copy(destination: destination, source: whenTrue), at: trueExpression.location, weight: 1)
                let endJump = emit(.jump(target: 0), at: location, weight: 1)
                patchJumpIfFalse(falseJump, target: instructions.count)
                let whenFalse = try compile(expression: falseExpression, format: format)
                emit(.copy(destination: destination, source: whenFalse), at: falseExpression.location, weight: 1)
                patchJump(endJump, target: instructions.count)
                return destination
            case let .call(name, arguments, location):
                return try compile(call: name, arguments: arguments, at: location, format: format)
            }
        }

        private mutating func compile(call name: String, arguments: [Expression], at location: Location, format: DSPAudioFormat) throws -> Int {
            if name == "inputAt" {
                guard arguments.count == 1,
                      let channel = try constantInteger(arguments[0], format: format),
                      (0..<format.channelCount).contains(channel) else {
                    throw DSPScriptCompiler.failure(
                        "script.invalidInputChannel",
                        "inputAt requires a constant channel index inside the source format.",
                        at: location
                    )
                }
                let destination = register()
                emit(.inputAt(destination: destination, channel: channel), at: location, weight: 2)
                return destination
            }
            if name == "biquad" {
                guard arguments.count == 6 else {
                    throw arityFailure(name, expected: 6, at: location)
                }
                let input = try compile(expression: arguments[0], format: format)
                var coefficients = [Double]()
                coefficients.reserveCapacity(5)
                for expression in arguments.dropFirst() {
                    coefficients.append(try DSPScriptCompiler.evaluateConstant(expression, constants: constantsInScope, format: format))
                }
                guard Self.isStableBiquad(coefficients) else {
                    throw DSPScriptCompiler.failure(
                        "script.invalidBiquad",
                        "Biquad coefficients must be finite and have a stable denominator.",
                        at: location
                    )
                }
                let slot = try addStateSlot(
                    name: nil,
                    kind: .biquad,
                    length: 2,
                    initialValue: 0,
                    delayOrdinal: nil,
                    at: location
                )
                let destination = register()
                emit(.biquad(destination: destination, input: input, coefficients: coefficients, stateSlot: slot), at: location, weight: 12)
                return destination
            }
            if name == "delay" {
                guard arguments.count == 2,
                      let frameCount = try constantInteger(arguments[1], format: format),
                      (0...65_536).contains(frameCount) else {
                    throw DSPScriptCompiler.failure(
                        "script.invalidDelay",
                        "delay requires an integer constant from 0 through 65536 frames.",
                        at: location
                    )
                }
                let input = try compile(expression: arguments[0], format: format)
                guard frameCount > 0 else { return input }
                let ordinal = delaySlotCount
                let slot = try addStateSlot(name: nil, kind: .delay, length: frameCount, initialValue: 0, delayOrdinal: ordinal, at: location)
                delaySlotCount += 1
                let destination = register()
                emit(.delay(destination: destination, input: input, stateSlot: slot), at: location, weight: 4)
                return destination
            }
            if name == "smooth" {
                guard arguments.count == 2 else { throw arityFailure(name, expected: 2, at: location) }
                let input = try compile(expression: arguments[0], format: format)
                let coefficient = try DSPScriptCompiler.evaluateConstant(arguments[1], constants: constantsInScope, format: format)
                guard coefficient >= 0, coefficient <= 1 else {
                    throw DSPScriptCompiler.failure("script.invalidSmoothCoefficient", "smooth coefficient must be between 0 and 1.", at: location)
                }
                let coefficientRegister = register()
                emit(.constant(destination: coefficientRegister, value: coefficient), at: location, weight: 0)
                let slot = try addStateSlot(name: nil, kind: .smooth, length: 1, initialValue: 0, delayOrdinal: nil, at: location)
                let destination = register()
                emit(.smooth(destination: destination, input: input, coefficient: coefficientRegister, stateSlot: slot), at: location, weight: 5)
                return destination
            }

            if name == "channel" || name == "channels" || name == "sampleRate" {
                guard arguments.isEmpty else { throw arityFailure(name, expected: 0, at: location) }
                let destination = register()
                switch name {
                case "channel": emit(.channel(destination: destination), at: location, weight: 1)
                case "channels": emit(.channels(destination: destination), at: location, weight: 0)
                default: emit(.sampleRate(destination: destination), at: location, weight: 0)
                }
                return destination
            }

            let expected: Int
            let unary: DSPScriptUnaryOperation?
            switch name {
            case "abs": expected = 1; unary = .absolute
            case "sqrt": expected = 1; unary = .squareRoot
            case "sin": expected = 1; unary = .sine
            case "cos": expected = 1; unary = .cosine
            case "tanh": expected = 1; unary = .tangentHyperbolic
            case "exp": expected = 1; unary = .exponential
            case "log": expected = 1; unary = .logarithm
            case "dbToGain": expected = 1; unary = .decibelsToGain
            default: expected = -1; unary = nil
            }
            if let unary {
                guard arguments.count == expected else { throw arityFailure(name, expected: expected, at: location) }
                let source = try compile(expression: arguments[0], format: format)
                let destination = register()
                let weight: Int
                switch unary {
                case .sine, .cosine, .tangentHyperbolic, .exponential, .logarithm, .decibelsToGain: weight = 16
                case .squareRoot: weight = 8
                default: weight = 1
                }
                emit(.unary(destination: destination, operation: unary, source: source), at: location, weight: weight)
                return destination
            }

            if name == "min" || name == "max" || name == "pow" {
                guard arguments.count == 2 else { throw arityFailure(name, expected: 2, at: location) }
                let left = try compile(expression: arguments[0], format: format)
                let right = try compile(expression: arguments[1], format: format)
                let destination = register()
                let operation: DSPScriptBinaryOperation = name == "min" ? .minimum : name == "max" ? .maximum : .power
                emit(.binary(destination: destination, operation: operation, left: left, right: right), at: location, weight: name == "pow" ? 8 : 1)
                return destination
            }
            if name == "clamp" {
                guard arguments.count == 3 else { throw arityFailure(name, expected: 3, at: location) }
                let value = try compile(expression: arguments[0], format: format)
                let minimum = try compile(expression: arguments[1], format: format)
                let maximum = try compile(expression: arguments[2], format: format)
                let lower = register()
                emit(.binary(destination: lower, operation: .maximum, left: value, right: minimum), at: location, weight: 1)
                let destination = register()
                emit(.binary(destination: destination, operation: .minimum, left: lower, right: maximum), at: location, weight: 1)
                return destination
            }
            if name == "mix" {
                guard arguments.count == 3 else { throw arityFailure(name, expected: 3, at: location) }
                let dry = try compile(expression: arguments[0], format: format)
                let wet = try compile(expression: arguments[1], format: format)
                let amount = try compile(expression: arguments[2], format: format)
                let destination = register()
                emit(.mix(destination: destination, dry: dry, wet: wet, amount: amount), at: location, weight: 3)
                return destination
            }
            throw DSPScriptCompiler.failure(
                "script.unknownFunction",
                "The function is not part of DSP script language version 1.",
                at: location,
                fieldPath: "process.\(name)"
            )
        }

        private mutating func constantInteger(_ expression: Expression, format: DSPAudioFormat) throws -> Int? {
            let value = try DSPScriptCompiler.evaluateConstant(expression, constants: constantsInScope, format: format)
            guard value.isFinite, value.rounded(.towardZero) == value,
                  value >= Double(Int.min), value < Double(Int.max) else { return nil }
            return Int(value)
        }

        private var constantsInScope: [String: Double] {
            var result = constants
            result.merge(localConstants) { _, local in local }
            return result
        }

        private mutating func addStateSlot(
            name: String?,
            kind: DSPScriptStateKind,
            length: Int,
            initialValue: Double,
            delayOrdinal: Int?,
            at location: Location
        ) throws -> Int {
            let maximumDoubleCount = DSPScriptCompiler.maximumStateBytes / MemoryLayout<Double>.stride
                / max(1, channelCount)
            guard length >= 0, stateStride <= maximumDoubleCount, length <= maximumDoubleCount - stateStride else {
                throw DSPScriptCompiler.failure(
                    "script.stateBudgetExceeded",
                    "The script's state exceeds the 4 MiB compile-time bound.",
                    at: location,
                    fieldPath: "state"
                )
            }
            let index = stateSlots.count
            stateSlots.append(DSPScriptStateSlot(
                name: name,
                kind: kind,
                offset: stateStride,
                length: length,
                initialValue: initialValue,
                delayOrdinal: delayOrdinal
            ))
            stateInitialValues.append(contentsOf: repeatElement(initialValue, count: length))
            stateStride += length
            return index
        }

        private mutating func register() -> Int {
            defer { registerCount += 1 }
            return registerCount
        }

        @discardableResult
        private mutating func emit(_ opcode: DSPScriptOpcode, at location: Location, weight: Int) -> Int {
            // Every emitted instruction runs in the per-sample VM, including
            // constants and jumps. A zero estimate here would let scripts pad
            // the instruction stream while bypassing the operations/second
            // budget.
            instructions.append(DSPScriptInstruction(
                opcode: opcode,
                line: location.line,
                column: location.column,
                weight: max(1, weight)
            ))
            return instructions.count - 1
        }

        private mutating func patchJumpIfFalse(_ index: Int, target: Int) {
            let old = instructions[index]
            guard case let .jumpIfFalse(condition, _) = old.opcode else { return }
            instructions[index] = DSPScriptInstruction(
                opcode: .jumpIfFalse(condition: condition, target: target),
                line: old.line,
                column: old.column,
                weight: old.weight
            )
        }

        private mutating func patchJump(_ index: Int, target: Int) {
            let old = instructions[index]
            guard case .jump = old.opcode else { return }
            instructions[index] = DSPScriptInstruction(opcode: .jump(target: target), line: old.line, column: old.column, weight: old.weight)
        }

        private func arityFailure(_ name: String, expected: Int, at location: Location) -> DSPScriptCompilationError {
            DSPScriptCompiler.failure("script.functionArity", "\(name) expects \(expected) argument(s).", at: location)
        }

        private func comparisonOperation(_ operation: String) -> DSPScriptComparisonOperation? {
            switch operation {
            case "<": return .lessThan
            case "<=": return .lessThanOrEqual
            case ">": return .greaterThan
            case ">=": return .greaterThanOrEqual
            case "==": return .equal
            case "!=": return .notEqual
            default: return nil
            }
        }

        private func binaryOperation(_ operation: String) -> DSPScriptBinaryOperation? {
            switch operation {
            case "+": return .add
            case "-": return .subtract
            case "*": return .multiply
            case "/": return .divide
            case "%": return .remainder
            case "^": return .power
            default: return nil
            }
        }

        private static func isStableBiquad(_ coefficients: [Double]) -> Bool {
            guard coefficients.count == 5, coefficients.allSatisfy(\.isFinite) else { return false }
            let a1 = coefficients[3]
            let a2 = coefficients[4]
            return abs(a2) < 1 && 1 + a1 + a2 > 0 && 1 - a1 + a2 > 0
        }
    }

    private static func evaluateConstant(
        _ expression: Expression,
        constants: [String: Double],
        format: DSPAudioFormat
    ) throws -> Double {
        let value: Double
        switch expression {
        case let .number(number, _):
            value = number
        case let .variable(name, location):
            guard let constant = constants[name] else {
                throw failure("script.nonConstantExpression", "This value must be known during prepare.", at: location)
            }
            value = constant
        case let .unary(operation, operand, location):
            let input = try evaluateConstant(operand, constants: constants, format: format)
            switch operation {
            case "-": value = -input
            case "!": value = input == 0 ? 1 : 0
            case "+": value = input
            default: throw failure("script.unsupportedOperator", "The unary operator is not supported.", at: location)
            }
        case let .binary(operation, leftExpression, rightExpression, location):
            let left = try evaluateConstant(leftExpression, constants: constants, format: format)
            let right = try evaluateConstant(rightExpression, constants: constants, format: format)
            switch operation {
            case "+": value = left + right
            case "-": value = left - right
            case "*": value = left * right
            case "/":
                guard right != 0 else { throw failure("script.constantDivisionByZero", "A constant expression divides by zero.", at: location) }
                value = left / right
            case "%":
                guard right != 0 else { throw failure("script.constantDivisionByZero", "A constant expression divides by zero.", at: location) }
                value = left.truncatingRemainder(dividingBy: right)
            case "^": value = pow(left, right)
            case "<": value = left < right ? 1 : 0
            case "<=": value = left <= right ? 1 : 0
            case ">": value = left > right ? 1 : 0
            case ">=": value = left >= right ? 1 : 0
            case "==": value = left == right ? 1 : 0
            case "!=": value = left != right ? 1 : 0
            default: throw failure("script.unsupportedOperator", "The binary operator is not supported.", at: location)
            }
        case let .conditional(condition, trueExpression, falseExpression, location):
            let selector = try evaluateConstant(condition, constants: constants, format: format)
            value = try evaluateConstant(selector != 0 ? trueExpression : falseExpression, constants: constants, format: format)
            _ = location
        case let .call(name, arguments, location):
            let values = try arguments.map { try evaluateConstant($0, constants: constants, format: format) }
            switch name {
            case "abs" where values.count == 1: value = abs(values[0])
            case "sqrt" where values.count == 1 && values[0] >= 0: value = sqrt(values[0])
            case "sin" where values.count == 1: value = sin(values[0])
            case "cos" where values.count == 1: value = cos(values[0])
            case "tanh" where values.count == 1: value = tanh(values[0])
            case "exp" where values.count == 1: value = exp(values[0])
            case "log" where values.count == 1 && values[0] > 0: value = log(values[0])
            case "dbToGain" where values.count == 1: value = pow(10, values[0] / 20)
            case "min" where values.count == 2: value = min(values[0], values[1])
            case "max" where values.count == 2: value = max(values[0], values[1])
            case "pow" where values.count == 2: value = pow(values[0], values[1])
            case "clamp" where values.count == 3: value = min(max(values[0], values[1]), values[2])
            case "mix" where values.count == 3: value = values[0] + (values[1] - values[0]) * values[2]
            case "channels" where values.isEmpty: value = Double(format.channelCount)
            case "sampleRate" where values.isEmpty: value = format.sampleRate
            default:
                throw failure("script.invalidPrepareFunction", "This function or its arguments are not valid in prepare.", at: location)
            }
        }
        guard value.isFinite else {
            throw failure("script.nonFiniteConstant", "Prepare expressions must produce finite values.", at: expression.location)
        }
        return value
    }

    private final class DSPScriptProgramCache: @unchecked Sendable {
        static let shared = DSPScriptProgramCache()

        private struct Entry {
            let key: String
            let baseKey: String
            let program: DSPScriptProgram
            let artifactBytes: Int
            var useOrdinal: UInt64
        }

        private let lock = NSLock()
        private var entries = [Entry]()
        private var totalBytes = 0
        private var nextOrdinal: UInt64 = 1

        func lookup(baseKey: String, suppliedValues: [String: Double]) -> DSPScriptProgram? {
            lock.lock()
            defer { lock.unlock() }
            guard let index = entries.indices.first(where: { entries[$0].baseKey == baseKey }) else { return nil }
            for entryIndex in entries.indices where entries[entryIndex].baseKey == baseKey {
                let program = entries[entryIndex].program
                let names = Set(program.parameters.map(\.name))
                guard Set(suppliedValues.keys).isSubset(of: names) else { continue }
                var matches = true
                for parameter in program.parameters {
                    let supplied = suppliedValues[parameter.name] ?? parameter.defaultValue
                    guard let expected = program.parameterValues[parameter.name],
                          supplied.bitPattern == expected.bitPattern else {
                        matches = false
                        break
                    }
                }
                guard matches else { continue }
                entries[entryIndex].useOrdinal = nextOrdinal
                nextOrdinal &+= 1
                return program
            }
            _ = index
            return nil
        }

        func insert(_ program: DSPScriptProgram, baseKey: String, valueKey: String, artifactBytes: Int) {
            guard artifactBytes > 0, artifactBytes <= DSPScriptCompiler.maximumCachedArtifactBytes else { return }
            lock.lock()
            defer { lock.unlock() }
            let key = "\(baseKey)|\(valueKey)"
            if let existing = entries.firstIndex(where: { $0.key == key }) {
                totalBytes -= entries[existing].artifactBytes
                entries.remove(at: existing)
            }
            while entries.count >= DSPScriptCompiler.maximumCachedPrograms
                    || totalBytes + artifactBytes > DSPScriptCompiler.maximumCachedArtifactBytes {
                guard let oldest = entries.indices.min(by: { entries[$0].useOrdinal < entries[$1].useOrdinal }) else { break }
                totalBytes -= entries[oldest].artifactBytes
                entries.remove(at: oldest)
            }
            entries.append(Entry(key: key, baseKey: baseKey, program: program, artifactBytes: artifactBytes, useOrdinal: nextOrdinal))
            nextOrdinal &+= 1
            totalBytes += artifactBytes
        }
    }

    private static func failure(
        _ code: String,
        _ message: String,
        at location: Location,
        fieldPath: String? = "source"
    ) -> DSPScriptCompilationError {
        DSPScriptCompilationError(diagnostics: [DSPDiagnostic(
            code: code,
            message: message,
            fieldPath: fieldPath,
            line: location.line,
            column: location.column
        )])
    }

    private static func sha256(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func formatKey(_ format: DSPAudioFormat) -> String {
        let layout = format.rawLayoutData?.base64EncodedString() ?? "-"
        let labels = format.channelLabels?.map { String($0) }.joined(separator: ",") ?? "-"
        return [
            String(format.sampleRate.bitPattern, radix: 16),
            String(format.channelCount),
            format.layoutIsKnown ? "1" : "0",
            layout,
            labels,
        ].joined(separator: ":")
    }

    private static func parameterKey(_ values: [String: Double]) -> String {
        values.keys.sorted().compactMap { key in
            guard let value = values[key] else { return nil }
            return "\(key)=\(String(value.bitPattern, radix: 16))"
        }.joined(separator: ";")
    }

    private static func runtimeStateBytes(
        channelCount: Int,
        stateStride: Int,
        registerCount: Int,
        delaySlotCount: Int,
        latencyFrames: Int
    ) -> Int {
        let doublesPerChannel = stateStride + latencyFrames
        let doubleStorage = (doublesPerChannel * channelCount + registerCount + channelCount * 4)
            * MemoryLayout<Double>.stride
        let indexStorage = (delaySlotCount * channelCount + channelCount)
            * MemoryLayout<Int>.stride
        return doubleStorage + indexStorage + 256
    }

    private static func worstCaseOperationsPerFrame(_ instructions: [DSPScriptInstruction]) -> Int {
        var costs = [Int](repeating: 0, count: instructions.count + 1)
        for index in instructions.indices.reversed() {
            let instruction = instructions[index]
            let continuation: Int
            switch instruction.opcode {
            case let .jumpIfFalse(_, target):
                guard target > index, target <= instructions.count else { return Int.max }
                continuation = max(costs[index + 1], costs[target])
            case let .jump(target):
                guard target > index, target <= instructions.count else { return Int.max }
                continuation = costs[target]
            default:
                continuation = costs[index + 1]
            }
            let (total, overflow) = instruction.weight.addingReportingOverflow(continuation)
            if overflow { return Int.max }
            costs[index] = total
        }
        return costs[0]
    }

    private static func estimatedArtifactBytes(_ program: DSPScriptProgram) -> Int {
        let instructionBytes = program.instructions.reduce(0) { total, instruction in
            let extra: Int
            if case let .biquad(_, _, coefficients, _) = instruction.opcode {
                extra = coefficients.count * MemoryLayout<Double>.stride
            } else {
                extra = 0
            }
            return total + MemoryLayout<DSPScriptInstruction>.stride + extra
        }
        let reflectionBytes = program.parameters.reduce(0) {
            $0 + $1.name.utf8.count + 3 * MemoryLayout<Double>.stride + 24
        }
        let stateBytes = program.stateSlots.count * MemoryLayout<DSPScriptStateSlot>.stride
            + program.stateInitializerValues.count * MemoryLayout<Double>.stride
        let parameterBytes = program.parameterValues.reduce(0) {
            $0 + $1.key.utf8.count + MemoryLayout<Double>.stride + 32
        }
        let formatBytes = (program.format.rawLayoutData?.count ?? 0)
            + (program.format.channelLabels?.count ?? 0) * MemoryLayout<UInt32>.stride
        return 128 + instructionBytes + reflectionBytes + stateBytes + parameterBytes
            + formatBytes + program.sourceHash.utf8.count
    }

    private static func isReservedName(_ name: String) -> Bool {
        ["input", "output", "inputAt", "channel", "channels", "sampleRate", "pi", "e"].contains(name)
    }

    private static func location(of statement: Statement) -> Location {
        switch statement {
        case let .letDeclaration(declaration): declaration.location
        case let .assignment(_, _, location): location
        }
    }
}
