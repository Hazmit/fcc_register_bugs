# fcc_register_bugs
This repository is to create a public space for users to enter bug reports for the FCC website app. This allows developers to track open issues and mark them solved when making code updates.

## Automatic triage

New issues start the Cursor issue triage workflow. It reads the code in `Hazmit/fcc_register` and comments on the issue. It opens a pull request on that code repository only when the report is a bug with enough detail and a small, confident fix.

The workflow needs an Actions secret named `CURSOR_API_KEY` (a Cursor user or service-account API key). The Cursor GitHub connection for that key must be able to read and write `Hazmit/fcc_register`.

Set the repository variable `CURSOR_TRIAGE_MODE` to `comment-only` to force analysis comments with no commits. Any other value, including leaving it unset, allows a pull request for a fixable bug.

To rerun triage for an existing issue, start the "Cursor issue triage" workflow manually and pass the issue number.
