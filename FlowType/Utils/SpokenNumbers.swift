import Foundation

/// Writes spoken numbers as digits, in Russian and English.
///
/// Russian: "двадцати пяти" → "25", "двадцать первый" → "21-й",
/// "двадцать пять процентов" → "25%", "пять тысяч рублей" → "5000 ₽",
/// "в девять тридцать" → "в 9:30"; dates and years take no ending, as in
/// edited text: "25 октября", "в 2026 году".
///
/// English: "twenty-five" → "25", "one hundred and five" → "105",
/// "twenty-first" → "21st", "five dollars" → "$5", "at nine thirty" →
/// "at 9:30", "nineteen ninety" → "1990", "October fifth" → "October 5".
///
/// With `keepsSmallNumbersAsWords`, zero to nine stay words ("у меня два
/// кота", "two cats") unless they are a percentage, money, a time or a
/// date. A number is read in one language; the words tell which.
nonisolated enum SpokenNumbers {
    static func digits(in text: String, keepsSmallNumbersAsWords: Bool) -> String {
        let tokens = splittingHyphenatedNumbers(text.split(separator: " ").map { Token(String($0)) })
        var output: [String] = []
        var index = 0

        while index < tokens.count {
            if let (replacement, next) = replacement(at: index, in: tokens, keepsSmallNumbersAsWords: keepsSmallNumbersAsWords) {
                output.append(replacement)
                index = next
            } else {
                output.append(tokens[index].text)
                index += 1
            }
        }
        return output.joined(separator: " ")
    }

    /// Whether `word`, as `TranscriptText.comparableWord` gives it, is a
    /// number word in either language: "двадцать", "шестом", "twenty".
    static func isNumberWord(_ word: String) -> Bool {
        cardinal(word) != nil || ordinal(word) != nil || scales[word] != nil || word == "hundred"
    }

    private enum Language {
        case russian, english
    }

    // MARK: - Reading a number

    private struct Token {
        let text: String
        let leading: String
        let trailing: String
        /// Lowercased, with ё as е and no punctuation around it. Unlike
        /// `TranscriptText.comparableWord` it keeps symbols, so "$5" isn't
        /// read as a bare 5.
        let core: String

        init(_ text: String) {
            self.text = text
            leading = String(text.prefix { $0.isPunctuation })
            trailing = String(text.reversed().prefix { $0.isPunctuation }.reversed())
            core = text.trimmingCharacters(in: .punctuationCharacters)
                .lowercased()
                .replacingOccurrences(of: "ё", with: "е")
        }

        /// A number the recogniser already wrote in digits.
        var typedValue: Int? {
            core.allSatisfy(\.isASCII) ? Int(core) : nil
        }
    }

    /// "twenty-five" and "twenty-first" read as two words. Only tens with
    /// units are split, and those always end up as digits, so no hyphen is
    /// lost; "fifty-fifty" and "one-two" stay as they are.
    private static func splittingHyphenatedNumbers(_ tokens: [Token]) -> [Token] {
        tokens.flatMap { token -> [Token] in
            let parts = token.core.split(separator: "-").map(String.init)
            guard parts.count == 2, englishCardinals[parts[0]]?.1 == .tens,
                  englishCardinals[parts[1]]?.1 == .units || englishOrdinals[parts[1]]?.1 == .units
            else {
                return [token]
            }
            let words = token.text.trimmingCharacters(in: .punctuationCharacters).split(separator: "-")
            return [Token(token.leading + words[0]), Token(words[1] + token.trailing)]
        }
    }

    /// A number read from one or more words.
    private struct Reading {
        var value: Int
        var end: Int
        /// Nil for a number typed in digits.
        var language: Language?
        /// What an ordinal takes after the digits: "-й", "-го", "st", "th"…
        var ordinalSuffix: String?
    }

    private enum Part {
        case none, hundreds, tens, teens, units, zero, scale

        private var order: Int {
            switch self {
            case .none: 0
            case .hundreds: 1
            case .tens: 2
            case .teens, .units: 3
            case .zero: 4
            case .scale: 5
            }
        }

        /// Hundreds, then tens, then units: "сто двадцать пять". Teens take
        /// the place of tens and units together: "сто одиннадцать", never
        /// "двадцать одиннадцать".
        func follows(_ previous: Part) -> Bool {
            !(self == .teens && previous == .tens) && order > previous.order
        }
    }

    private static func read(at start: Int, in tokens: [Token]) -> Reading? {
        // A bare number from the recogniser counts too, so "25 процентов"
        // becomes "25%" like "двадцать пять процентов".
        if let value = tokens[start].typedValue {
            return Reading(value: value, end: start + 1)
        }

        var reading = Reading(value: 0, end: start)
        var total = 0
        var group = 0
        var lastPart = Part.none
        var lastScale = Int.max
        var index = start

        func accepts(_ language: Language) -> Bool {
            reading.language.map { $0 == language } ?? true
        }

        while index < tokens.count {
            let core = tokens[index].core
            let next = index + 1 < tokens.count ? tokens[index + 1].core : nil

            if let (value, part, language) = cardinal(core), accepts(language),
               // "сорока" alone is mostly the magpie: only "сорока пяти" or
               // "ста сорока" are numbers.
               core != "сорока" || lastPart == .hundreds || next.flatMap({ russianCardinals[$0]?.1 }) == .units {
                if part == .zero {
                    guard index == start else { break }
                    return Reading(value: 0, end: index + 1, language: language)
                }
                guard part.follows(lastPart) else { break }
                group += value
                lastPart = part
                reading.language = language
            } else if core == "hundred", accepts(.english), lastPart != .hundreds, lastPart != .none || group == 0 {
                // English hundreds multiply: "two hundred", "nineteen hundred".
                group = max(group, 1) * 100
                lastPart = .hundreds
                reading.language = .english
            } else if let scale = scales[core], accepts(scale.language) {
                guard scale.value < lastScale,
                      // Without a number before it only the singular is a
                      // number: "тысяча рублей", but "тысячи людей" are many.
                      group > 0 || scale.isSingular
                else {
                    break
                }
                total += max(group, 1) * scale.value
                group = 0
                lastPart = .none
                lastScale = scale.value
                reading.language = scale.language
            } else if let ordinal = ordinal(core), accepts(ordinal.language) {
                if ordinal.part == .scale {
                    guard ordinal.value < lastScale else { break }
                    total += max(group, 1) * ordinal.value
                    group = 0
                } else if core == "hundredth" {
                    guard lastPart != .hundreds else { break }
                    group = max(group, 1) * 100
                } else {
                    // "second" is mostly the unit of time: "one second".
                    guard ordinal.part.follows(lastPart), core != "second" || lastPart == .tens else { break }
                    group += ordinal.value
                }
                let value = total + group
                let suffix = ordinal.russianEnding.map { "-" + $0 } ?? englishOrdinalSuffix(value)
                return Reading(value: value, end: index + 1, language: ordinal.language, ordinalSuffix: suffix)
            } else if core == "a", index == start, tokens[index].trailing.isEmpty,
                      let next, next == "hundred" || scales[next]?.language == .english {
                // "a hundred", "a thousand".
                group = 1
                lastPart = .units
                reading.language = .english
            } else if core == "and", reading.language == .english,
                      // After hundreds or a scale word: "two thousand and five".
                      lastPart == .hundreds || lastPart == .none,
                      let next, englishCardinals[next] != nil || englishOrdinals[next] != nil {
                // "one hundred and five".
            } else {
                break
            }

            index += 1
            // A comma or a full stop ends the number.
            if !tokens[index - 1].trailing.isEmpty {
                break
            }
        }

        guard index > start else { return nil }
        // An "and" the next word didn't continue belongs to the text: "one
        // hundred and second".
        if tokens[index - 1].core == "and" {
            index -= 1
        }
        reading.value = total + group
        reading.end = index
        return reading
    }

    // MARK: - Writing it

    private static func replacement(
        at start: Int, in tokens: [Token], keepsSmallNumbersAsWords: Bool
    ) -> (String, Int)? {
        guard let number = read(at: start, in: tokens) else { return nil }
        let first = tokens[start]
        let last = tokens[number.end - 1]
        let next = number.end < tokens.count && last.trailing.isEmpty ? tokens[number.end] : nil
        let previous = start > 0 && tokens[start - 1].trailing.isEmpty ? tokens[start - 1].core : nil

        // "двадцать пять процентов" → "25%", "twenty-five percent" → "25%".
        if number.ordinalSuffix == nil, let next, percentWords.contains(next.core) {
            return (first.leading + "\(number.value)%" + next.trailing, number.end + 1)
        }
        // "пять тысяч рублей" → "5000 ₽", "five dollars" → "$5".
        if number.ordinalSuffix == nil, let next, let currency = currencies[next.core] {
            let amount = formatted(number.value, in: currency.language)
            let money = currency.language == .english ? currency.sign + amount : amount + "\u{00A0}" + currency.sign
            return (first.leading + money + next.trailing, number.end + 1)
        }
        // A Russian year said in two halves, "двадцать двадцать шесть", or
        // "20 26" from the recogniser. It is a year before "году" or at the
        // end of a phrase: "в двадцать двадцать шестом году" → "в 2026 году",
        // "двадцать двадцать шесть." → "2026.". Before any other word, a
        // repeated first word is a stutter: "через двадцать двадцать пять
        // минут" → "через 25 минут". After "в" or "к" it is a time, read
        // below. The English halves are read with the times too.
        if number.ordinalSuffix == nil, (19...20).contains(number.value), let next,
           let second = read(at: number.end, in: tokens), second.language == number.language {
            let isWritten = number.language == .russian && (10...99).contains(second.value)
            let isTyped = number.language == nil && next.core.count == 2
            let after = second.end < tokens.count && tokens[second.end - 1].trailing.isEmpty ? tokens[second.end] : nil
            let isBeforeYearWord = after.map { russianYearWords.contains($0.core) } ?? false
            let endsPhrase = after == nil && !timePrepositions.contains(previous ?? "")
            if (isWritten || isTyped) && (isBeforeYearWord || endsPhrase) {
                // "в 2026 году", but "двадцать двадцать пятый." → "2025-й.".
                let ending = isBeforeYearWord ? "" : (second.ordinalSuffix ?? "") + tokens[second.end - 1].trailing
                return (first.leading + "\(number.value * 100 + second.value)" + ending, second.end)
            }
            if isWritten, first.core == next.core, !isBeforeYearWord {
                return replacement(at: number.end, in: tokens, keepsSmallNumbersAsWords: keepsSmallNumbersAsWords)
                    .map { (first.leading + $0.0, $0.1) } ?? (first.leading + next.text, number.end + 1)
            }
        }

        // Typed digits are otherwise left as the recogniser wrote them.
        guard let language = number.language else { return nil }

        // Two numbers in a row: "в девять тридцать" → "в 9:30", "nineteen
        // ninety" → "1990". Without a word that says which, the pair stays
        // as spoken: "one fifty" may be a price.
        if number.ordinalSuffix == nil, number.value < 24, next != nil,
           let (second, end) = secondHalf(at: number.end, in: tokens, language: language) {
            let isYear = language == .english && !timePrepositions.contains(previous ?? "")
                && ((19...20).contains(number.value) || ((10...20).contains(number.value) && yearPrepositions.contains(previous ?? "")))
            if isYear {
                return (first.leading + "\(number.value * 100 + second)" + tokens[end - 1].trailing, end)
            }
            if second < 60, timePrepositions.contains(previous ?? "") {
                let time = "\(number.value):" + (second < 10 ? "0" : "") + "\(second)"
                return (first.leading + time + tokens[end - 1].trailing, end)
            }
            return (tokens[start..<end].map(\.text).joined(separator: " "), end)
        }

        let digits = formatted(number.value, in: language)
        let staysWords = number.value < 10 && keepsSmallNumbersAsWords

        if let suffix = number.ordinalSuffix {
            // Dates and years take no ending: "25 октября", "в 2026 году",
            // "October 5".
            let isDay = (1...31).contains(number.value)
            let isBareDate = switch language {
            case .russian:
                next.map { (isDay && russianMonths.contains($0.core)) || (number.value >= 1000 && russianYearWords.contains($0.core)) } ?? false
            case .english:
                // Months are capitalised; "may" in "you may first" is a verb.
                isDay && start > 0 && previous.map(englishMonths.contains) == true
                    && tokens[start - 1].text.first?.isUppercase == true
            }
            // "the fifth of October" → "the 5th of October".
            let isDateWithOf = language == .english && isDay && next?.core == "of"
                && number.end + 1 < tokens.count && englishMonths.contains(tokens[number.end + 1].core)
            guard !staysWords || isBareDate || isDateWithOf else { return nil }
            return (first.leading + digits + (isBareDate ? "" : suffix) + last.trailing, number.end)
        }

        guard !staysWords else { return nil }
        return (first.leading + digits + last.trailing, number.end)
    }

    /// What follows an hour or the first half of an English year: minutes
    /// ("тридцать", "сорок пять", "ноль пять", "oh five") or the year's last
    /// two digits ("ninety").
    private static func secondHalf(at start: Int, in tokens: [Token], language: Language) -> (Int, Int)? {
        guard start < tokens.count else { return nil }
        // "ноль пять", "oh five".
        if tokens[start].core == "oh" || cardinal(tokens[start].core)?.1 == .zero {
            guard start + 1 < tokens.count, tokens[start].trailing.isEmpty,
                  let units = read(at: start + 1, in: tokens), units.language == language,
                  units.ordinalSuffix == nil, (1...9).contains(units.value)
            else {
                return nil
            }
            return (units.value, units.end)
        }
        guard let reading = read(at: start, in: tokens), reading.language == language,
              reading.ordinalSuffix == nil, (10...99).contains(reading.value)
        else {
            return nil
        }
        return (reading.value, reading.end)
    }

    /// "15000" → "15 000" in Russian, "15,000" in English; four digits stay
    /// together, like years.
    private static func formatted(_ value: Int, in language: Language) -> String {
        let digits = String(value)
        guard digits.count > 4 else { return digits }
        var groups: [String] = []
        var rest = Substring(digits)
        while rest.count > 3 {
            groups.insert(String(rest.suffix(3)), at: 0)
            rest = rest.dropLast(3)
        }
        groups.insert(String(rest), at: 0)
        return groups.joined(separator: language == .english ? "," : "\u{00A0}")
    }

    private static func englishOrdinalSuffix(_ value: Int) -> String {
        if (11...13).contains(value % 100) {
            return "th"
        }
        switch value % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    // MARK: - Words

    private static func cardinal(_ word: String) -> (Int, Part, Language)? {
        if let (value, part) = russianCardinals[word] {
            return (value, part, .russian)
        }
        if let (value, part) = englishCardinals[word] {
            return (value, part, .english)
        }
        return nil
    }

    /// Every case form of the Russian cardinals. Forms that are mostly other
    /// words are left out: "семью" (семья), "одни" ("одни дома").
    private static let russianCardinals: [String: (Int, Part)] = {
        var table: [String: (Int, Part)] = [:]
        func add(_ value: Int, _ part: Part, _ forms: [String]) {
            for form in forms {
                table[form] = (value, part)
            }
        }
        add(0, .zero, ["ноль", "нуль", "ноля", "нуля", "нолю", "нулю", "нолем", "нулем"])
        add(1, .units, ["один", "одного", "одному", "одним", "одном", "одна", "одной", "одну", "одно"])
        add(2, .units, ["два", "две", "двух", "двум", "двумя"])
        add(3, .units, ["три", "трех", "трем", "тремя"])
        add(4, .units, ["четыре", "четырех", "четырем", "четырьмя"])
        add(5, .units, ["пять", "пяти", "пятью"])
        add(6, .units, ["шесть", "шести", "шестью"])
        add(7, .units, ["семь", "семи"])
        add(8, .units, ["восемь", "восьми", "восемью", "восьмью"])
        add(9, .units, ["девять", "девяти", "девятью"])
        let teens = ["десять", "одиннадцать", "двенадцать", "тринадцать", "четырнадцать",
                     "пятнадцать", "шестнадцать", "семнадцать", "восемнадцать", "девятнадцать"]
        for (offset, word) in teens.enumerated() {
            let stem = String(word.dropLast())
            add(10 + offset, .teens, [word, stem + "и", stem + "ью"])
        }
        add(20, .tens, ["двадцать", "двадцати", "двадцатью"])
        add(30, .tens, ["тридцать", "тридцати", "тридцатью"])
        add(40, .tens, ["сорок", "сорока"])
        add(50, .tens, ["пятьдесят", "пятидесяти", "пятьюдесятью"])
        add(60, .tens, ["шестьдесят", "шестидесяти", "шестьюдесятью"])
        add(70, .tens, ["семьдесят", "семидесяти", "семьюдесятью"])
        add(80, .tens, ["восемьдесят", "восьмидесяти", "восемьюдесятью", "восьмьюдесятью"])
        add(90, .tens, ["девяносто", "девяноста"])
        add(100, .hundreds, ["сто", "ста"])
        add(200, .hundreds, ["двести", "двухсот", "двумстам", "двумястами", "двухстах"])
        add(300, .hundreds, ["триста", "трехсот", "тремстам", "тремястами", "трехстах"])
        add(400, .hundreds, ["четыреста", "четырехсот", "четыремстам", "четырьмястами", "четырехстах"])
        add(500, .hundreds, ["пятьсот", "пятисот", "пятистам", "пятьюстами", "пятистах"])
        add(600, .hundreds, ["шестьсот", "шестисот", "шестистам", "шестьюстами", "шестистах"])
        add(700, .hundreds, ["семьсот", "семисот", "семистам", "семьюстами", "семистах"])
        add(800, .hundreds, ["восемьсот", "восьмисот", "восьмистам", "восемьюстами", "восьмистах"])
        add(900, .hundreds, ["девятьсот", "девятисот", "девятистам", "девятьюстами", "девятистах"])
        return table
    }()

    /// English cardinals; "hundred" multiplies and is read on its own.
    private static let englishCardinals: [String: (Int, Part)] = {
        var table: [String: (Int, Part)] = ["zero": (0, .zero)]
        let units = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        for (offset, word) in units.enumerated() {
            table[word] = (offset + 1, .units)
        }
        let teens = ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        for (offset, word) in teens.enumerated() {
            table[word] = (offset + 10, .teens)
        }
        let tens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        for (offset, word) in tens.enumerated() {
            table[word] = ((offset + 2) * 10, .tens)
        }
        return table
    }()

    /// Thousands, millions and billions. Without a number before it only
    /// the singular counts: "thousands of people" are many.
    private static let scales: [String: (value: Int, language: Language, isSingular: Bool)] = {
        var table: [String: (value: Int, language: Language, isSingular: Bool)] = [:]
        for form in ["тысяча", "тысяче", "тысячу", "тысячей", "тысячею"] {
            table[form] = (1000, .russian, true)
        }
        for form in ["тысячи", "тысяч", "тысячам", "тысячами", "тысячах"] {
            table[form] = (1000, .russian, false)
        }
        for (stem, value) in [("миллион", 1_000_000), ("миллиард", 1_000_000_000)] {
            for ending in ["", "а", "у", "ом", "е"] {
                table[stem + ending] = (value, .russian, true)
            }
            for ending in ["ы", "ов", "ам", "ами", "ах"] {
                table[stem + ending] = (value, .russian, false)
            }
        }
        table["thousand"] = (1000, .english, true)
        table["million"] = (1_000_000, .english, true)
        table["billion"] = (1_000_000_000, .english, true)
        return table
    }()

    private struct Ordinal {
        let value: Int
        let part: Part
        let language: Language
        let russianEnding: String?
    }

    private static func ordinal(_ word: String) -> Ordinal? {
        if let (value, part) = englishOrdinals[word] {
            return Ordinal(value: value, part: part, language: .english, russianEnding: nil)
        }
        return russianOrdinals[word]
    }

    /// Every form of the Russian ordinals: each stem with each adjective
    /// ending, and "третий" with its own.
    private static let russianOrdinals: [String: Ordinal] = {
        var table: [String: Ordinal] = [:]
        for (stem, value, part) in russianOrdinalStems {
            for (suffix, written) in russianOrdinalEndings {
                table[stem + suffix] = Ordinal(value: value, part: part, language: .russian, russianEnding: written)
            }
        }
        for (form, written) in russianThirdForms {
            table[form] = Ordinal(value: 3, part: .units, language: .russian, russianEnding: written)
        }
        return table
    }()

    /// Russian ordinal stems; the endings come from `russianOrdinalEndings`.
    private static let russianOrdinalStems: [(String, Int, Part)] = [
        ("нулев", 0, .zero), ("перв", 1, .units), ("втор", 2, .units), ("четверт", 4, .units),
        ("пят", 5, .units), ("шест", 6, .units), ("седьм", 7, .units), ("восьм", 8, .units),
        ("девят", 9, .units), ("десят", 10, .teens), ("одиннадцат", 11, .teens),
        ("двенадцат", 12, .teens), ("тринадцат", 13, .teens), ("четырнадцат", 14, .teens),
        ("пятнадцат", 15, .teens), ("шестнадцат", 16, .teens), ("семнадцат", 17, .teens),
        ("восемнадцат", 18, .teens), ("девятнадцат", 19, .teens), ("двадцат", 20, .tens),
        ("тридцат", 30, .tens), ("сороков", 40, .tens), ("пятидесят", 50, .tens),
        ("шестидесят", 60, .tens), ("семидесят", 70, .tens), ("восьмидесят", 80, .tens),
        ("девяност", 90, .tens), ("сот", 100, .hundreds), ("двухсот", 200, .hundreds),
        ("трехсот", 300, .hundreds), ("четырехсот", 400, .hundreds), ("пятисот", 500, .hundreds),
        ("шестисот", 600, .hundreds), ("семисот", 700, .hundreds), ("восьмисот", 800, .hundreds),
        ("девятисот", 900, .hundreds), ("тысячн", 1000, .scale), ("двухтысячн", 2000, .scale),
        ("миллионн", 1_000_000, .scale),
    ]

    /// Adjective endings and the ending written after the digits.
    private static let russianOrdinalEndings: [(String, String)] = [
        ("ыми", "ми"), ("ими", "ми"), ("ого", "го"), ("его", "го"), ("ому", "му"), ("ему", "му"),
        ("ый", "й"), ("ой", "й"), ("ий", "й"), ("ая", "я"), ("яя", "я"), ("ое", "е"), ("ее", "е"),
        ("ым", "м"), ("им", "м"), ("ом", "м"), ("ем", "м"), ("ую", "ю"), ("юю", "ю"),
        ("ые", "е"), ("ие", "е"), ("ых", "х"), ("их", "х"),
    ]

    /// "третий" declines on its own pattern.
    private static let russianThirdForms: [String: String] = [
        "третий": "й", "третья": "я", "третье": "е", "третьего": "го", "третьему": "му",
        "третьим": "м", "третьем": "м", "третью": "ю", "третьи": "и", "третьих": "х", "третьими": "ми",
    ]

    /// English ordinals; "hundredth" multiplies like "hundred".
    private static let englishOrdinals: [String: (Int, Part)] = {
        var table: [String: (Int, Part)] = ["zeroth": (0, .zero)]
        let units = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth"]
        for (offset, word) in units.enumerated() {
            table[word] = (offset + 1, .units)
        }
        let teens = ["tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth",
                     "sixteenth", "seventeenth", "eighteenth", "nineteenth"]
        for (offset, word) in teens.enumerated() {
            table[word] = (offset + 10, .teens)
        }
        let tens = ["twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth", "seventieth", "eightieth", "ninetieth"]
        for (offset, word) in tens.enumerated() {
            table[word] = ((offset + 2) * 10, .tens)
        }
        table["hundredth"] = (100, .hundreds)
        table["thousandth"] = (1000, .scale)
        table["millionth"] = (1_000_000, .scale)
        table["billionth"] = (1_000_000_000, .scale)
        return table
    }()

    private static let percentWords: Set<String> = [
        "процент", "процента", "процентов", "проценту", "процентам", "процентом", "процентами", "проценте", "процентах",
        "percent",
    ]

    private static let currencies: [String: (sign: String, language: Language)] = {
        var table: [String: (sign: String, language: Language)] = [:]
        for form in ["рубль", "рубля", "рублей", "рублю", "рублям", "рублем", "рублями", "рубле", "рублях"] {
            table[form] = ("₽", .russian)
        }
        for form in ["доллар", "доллара", "долларов", "доллару", "долларам", "долларом", "долларами", "долларе", "долларах"] {
            table[form] = ("$", .russian)
        }
        table["евро"] = ("€", .russian)
        // Pounds are left alone: "five pounds" is as often a weight.
        for form in ["dollar", "dollars", "buck", "bucks"] {
            table[form] = ("$", .english)
        }
        for form in ["euro", "euros"] {
            table[form] = ("€", .english)
        }
        return table
    }()

    /// Words before an hour that make two numbers a time.
    private static let timePrepositions: Set<String> = [
        "в", "к", "до", "после", "с", "со", "около", "на", "от",
        "at", "by", "until", "till", "from", "around", "before", "after",
    ]

    /// Words before an English year's first half that make a pair a year
    /// even below nineteen hundred: "in sixteen sixty".
    private static let yearPrepositions: Set<String> = ["in", "since", "of", "year"]

    private static let russianMonths: Set<String> = [
        "января", "февраля", "марта", "апреля", "мая", "июня",
        "июля", "августа", "сентября", "октября", "ноября", "декабря",
    ]

    private static let englishMonths: Set<String> = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
    ]

    /// "в 2026 году", but "в 90-х годах".
    private static let russianYearWords: Set<String> = ["год", "года", "году", "годом", "годе"]
}
