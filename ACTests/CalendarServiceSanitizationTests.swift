import Foundation
import Testing
@testable import AC

struct CalendarServiceSanitizationTests {

    @Test
    func stripsGoogleTasksEditDisclaimerFromNotes() {
        let raw = """
        restart and update mal
        Changes made to the title, description, or attachments will not be saved.
        To make edits, please go to: https://tasks.google.com/task/S4VSgNzEe4E9fv3w
        """

        let sanitized = CalendarService.sanitizeNotesForPrompt(raw)

        #expect(sanitized == "restart and update mal")
        #expect(sanitized.contains("Changes made to the title") == false)
        #expect(sanitized.contains("tasks.google.com") == false)
    }

    @Test
    func compactsWhitespaceForPromptSafety() {
        let raw = "  ship patch\n\nwith tests\r\n  today  "

        let sanitized = CalendarService.sanitizeNotesForPrompt(raw)

        #expect(sanitized == "ship patch with tests today")
    }
}
