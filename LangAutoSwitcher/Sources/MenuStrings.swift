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
        case languageAddedTitle
        case languageAddedBody
        case languageRemovedTitle
        case restartNeeded
        case removeLanguageMenu
        case addLanguagePrompt
        case leadLanguagePrompt
        case removeLanguagePrompt
        case leadLanguageSet
        case downloadingBody
        case nothingToChoose
        case ok
        case cancel
        case forgetForcedWords
        case reloadLearned
        case editKeymap
        case reloadKeymap
        case resetKeymap
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
            .languageAddedTitle: "%@ added",
            .languageAddedBody:  "%@ is ready. Quit and reopen the app you are typing in (or log out and back in) and then just type as you normally do — it will switch automatically.",
            .languageRemovedTitle: "%@ removed",
            .restartNeeded:      "Reopen the app you are typing in for this to take effect.",
            .removeLanguageMenu: "Remove a language…",
            .addLanguagePrompt:  "Pick a language to add. Its dictionary downloads once.",
            .leadLanguagePrompt: "The main language wins when a word could be either, and this menu is written in it.",
            .removeLanguagePrompt: "Pick a language to stop using.",
            .leadLanguageSet:    "%@ is now your main language.",
            .downloadingBody:    "Downloading the dictionary — this takes a moment.",
            .nothingToChoose:    "There is nothing to choose here.",
            .ok:                 "OK",
            .cancel:             "Cancel",
            .forgetForcedWords:  "Forget the words I forced (%@)",
            .reloadLearned:      "Reload learned words",
            .editKeymap:         "Edit the keyboard map…",
            .reloadKeymap:       "Reload the keyboard map",
            .resetKeymap:        "Reset the keyboard map",
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
            .languageAddedTitle: "%@ е добавен",
            .languageAddedBody:  "%@ е готов. Затвори и отвори отново приложението, в което пишеш (или излез и влез в профила си), и просто пиши както обикновено — ще превключва само.",
            .languageRemovedTitle: "%@ е премахнат",
            .restartNeeded:      "Затвори и отвори отново приложението, в което пишеш, за да влезе в сила.",
            .removeLanguageMenu: "Премахни език…",
            .addLanguagePrompt:  "Избери език за добавяне. Речникът му се изтегля веднъж.",
            .leadLanguagePrompt: "Основният език печели, когато думата може да е и на двата, и това меню е на него.",
            .removeLanguagePrompt: "Избери език, който да спреш да ползваш.",
            .leadLanguageSet:    "%@ вече е основният ти език.",
            .downloadingBody:    "Изтегля се речникът — това отнема момент.",
            .nothingToChoose:    "Няма какво да се избира тук.",
            .ok:                 "Добре",
            .cancel:             "Отказ",
            .forgetForcedWords:  "Забрави наложените думи (%@)",
            .reloadLearned:      "Презареди научените думи",
            .editKeymap:         "Редактирай клавишите…",
            .reloadKeymap:       "Презареди клавишите",
            .resetKeymap:        "Върни клавишите по подразбиране",
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
            .languageAddedTitle: "%@ добавлен",
            .languageAddedBody:  "%@ готов. Закройте и снова откройте приложение, в котором печатаете, и просто печатайте как обычно — переключение произойдёт само.",
            .languageRemovedTitle: "%@ удалён",
            .restartNeeded:      "Закройте и снова откройте приложение, в котором печатаете.",
            .removeLanguageMenu: "Удалить язык…",
            .addLanguagePrompt:  "Выберите язык для добавления. Его словарь загрузится один раз.",
            .leadLanguagePrompt: "Основной язык побеждает, когда слово может быть на любом из них, и это меню написано на нём.",
            .removeLanguagePrompt: "Выберите язык, который больше не нужен.",
            .leadLanguageSet:    "%@ теперь ваш основной язык.",
            .downloadingBody:    "Загружается словарь — это займёт момент.",
            .nothingToChoose:    "Здесь нечего выбирать.",
            .ok:                 "ОК",
            .cancel:             "Отмена",
            .forgetForcedWords:  "Забыть навязанные слова (%@)",
            .reloadLearned:      "Перезагрузить запомненные слова",
            .editKeymap:         "Изменить раскладку…",
            .reloadKeymap:       "Перезагрузить раскладку",
            .resetKeymap:        "Сбросить раскладку",
        ],
    ]
}
