/// The Automations screens (docs/ui/ui-spec.md 2.1 to 2.5) and scenes.
/// Other screens import this one file.
library;

export 'automation_page.dart' show AutomationPage;
export 'automations_screen.dart'
    show AutomationsScreen, AutomationCard, automationsAreEmpty;
export 'automations_state.dart' show automationsProvider, AutomationsNotifier;
export 'link_sheet.dart' show LinkSheet;
export 'new_automation.dart' show openNewAutomation, TemplatePage;
export 'review_page.dart' show ReviewPage;
export 'rule_editor.dart' show RuleEditorPage, openRuleEditor;
export 'scenes.dart'
    show
        ScenesPage,
        SceneEditorPage,
        automationIconFor,
        openScenes,
        openSceneEditor,
        runScene,
        sceneIconFor,
        sceneIcons;
export 'test_run.dart' show RunPage, TestRunPage, runSummary;
export 'waiting_page.dart' show WaitingPage, openWaitingForApproval;
