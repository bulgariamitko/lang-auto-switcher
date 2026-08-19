import Foundation

/// The menu's own wording, in the user's lead language.
///
/// Translations are hand-written, so only languages someone has actually
/// translated appear here; everything else falls back to English rather than
/// showing a machine-mangled menu. Adding a language to the app does NOT
/// require adding it here.
enum MenuStrings {

    enum Key: String {
        case defaultForUnknown
        case languages
        case addLanguage
        case removeLanguage
        case leadLanguage
        case autocorrect
        case fixTypos
        case revertLastWord
        case forceToLanguage
        case learnedWords
        case forgetLearned
        case disableForApp
        case enableForApp
        case editExclusions
        case reloadExclusions
        case checkForUpdates
        case diagnostics
        case quit
        case noDictionary
        case downloading
    }

    /// Which language the menu is written in. Follows the lead language when
    /// we have a translation for it, English otherwise.
    static var current: String {
        let lead = LanguagePackStore.leadCode
        return tables[lead] != nil ? lead : "en"
    }

    static func t(_ key: Key) -> String {
        tables[current]?[key] ?? tables["en"]?[key] ?? key.rawValue
    }

    /// Interpolating variant for the items that name something.
    static func t(_ key: Key, _ argument: String) -> String {
        t(key).replacingOccurrences(of: "%@", with: argument)
    }

    private static let tables: [String: [Key: String]] = [
        "en": [
            .defaultForUnknown: "Default for unknown words:",
            .languages:         "Languages",
            .addLanguage:       "Add language…",
            .removeLanguage:    "Remove “%@”",
            .leadLanguage:      "Main language",
            .autocorrect:       "Autocorrect (w → with)",
            .fixTypos:          "Fix typing mistakes",
            .revertLastWord:    "Undo last word (⌥⌘Z)",
            .forceToLanguage:   "Force last word to %@ (⌥⌘B)",
            .learnedWords:      "Learned words: %@",
            .forgetLearned:     "Forget all learned words",
            .disableForApp:     "Disable for: %@",
            .enableForApp:      "Enable again for: %@",
            .editExclusions:    "Edit the exclusion list…",
            .reloadExclusions:  "Reload the exclusion list",
            .checkForUpdates:   "Check for updates…",
            .diagnostics:       "Diagnostics",
            .quit:              "Quit",
            .noDictionary:      "%@ — no dictionary installed",
            .downloading:       "Downloading %@…",
        ],
        "bg": [
            .defaultForUnknown: "По подразбиране за непознати думи:",
            .languages:         "Езици",
            .addLanguage:       "Добави език…",
            .removeLanguage:    "Премахни „%@“",
            .leadLanguage:      "Основен език",
            .autocorrect:       "Автокорекция (w → with)",
            .fixTypos:          "Поправяй печатни грешки",
            .revertLastWord:    "Върни последната дума (⌥⌘Z)",
            .forceToLanguage:   "Направи последната дума на %@ (⌥⌘B)",
            .learnedWords:      "Запомнени думи: %@",
            .forgetLearned:     "Забрави всички запомнени думи",
            .disableForApp:     "Изключи за: %@",
            .enableForApp:      "Включи отново за: %@",
            .editExclusions:    "Редактирай списъка с изключения…",
            .reloadExclusions:  "Презареди списъка с изключения",
            .checkForUpdates:   "Провери за обновления…",
            .diagnostics:       "Диагностика",
            .quit:              "Изход",
            .noDictionary:      "%@ — няма инсталиран речник",
            .downloading:       "Изтегляне на %@…",
        ],
        "ru": [
            .defaultForUnknown: "По умолчанию для неизвестных слов:",
            .languages:         "Языки",
            .addLanguage:       "Добавить язык…",
            .removeLanguage:    "Удалить «%@»",
            .leadLanguage:      "Основной язык",
            .autocorrect:       "Автозамена (w → with)",
            .fixTypos:          "Исправлять опечатки",
            .revertLastWord:    "Отменить последнее слово (⌥⌘Z)",
            .forceToLanguage:   "Сделать последнее слово на %@ (⌥⌘B)",
            .learnedWords:      "Запомненные слова: %@",
            .forgetLearned:     "Забыть все запомненные слова",
            .disableForApp:     "Отключить для: %@",
            .enableForApp:      "Включить снова для: %@",
            .editExclusions:    "Изменить список исключений…",
            .reloadExclusions:  "Перезагрузить список исключений",
            .checkForUpdates:   "Проверить обновления…",
            .diagnostics:       "Диагностика",
            .quit:              "Выход",
            .noDictionary:      "%@ — словарь не установлен",
            .downloading:       "Загрузка %@…",
        ],
    ]
}
