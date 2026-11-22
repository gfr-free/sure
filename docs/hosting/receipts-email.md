# Receipts by e-mail

Receipts is a preview feature. Users who turned on preview features can upload
receipts on the Receipts page. With the settings below, each of them can also
switch on a private e-mail address and forward invoices and receipts to it.
Sure adds every PDF and photo attached to such a mail to that user's receipts.
The mail text is not kept.

## Addresses

Set the base address of a mailbox that accepts plus addressing:

```bash
RECEIPT_INBOX_ADDRESS=receipts@mail.example.com
```

A user's address then looks like `receipts+k3j9...@mail.example.com`. The part
after the `+` is a random token that identifies the user. Sure accepts a mail
only if it comes from the user's login address or from one of the extra sender
addresses the user entered on the Receipts page. A sender address can be forged,
so the token is the real secret: a user who suspects the address leaked can get
a new one, and the old one stops working at once.

From each mail, Sure takes at most 10 attachments, each up to 10 MB. Images
under 10 KB are skipped because they are almost always logos or signatures.
The same file is never added twice for the same user.

## Option 1: IMAP (no public mail endpoint needed)

Sure checks the mailbox every 5 minutes, takes every unread mail and then
deletes it. Use a mailbox that only serves this purpose.

```bash
RECEIPT_INBOX_IMAP_HOST=imap.example.com
RECEIPT_INBOX_IMAP_PORT=993
RECEIPT_INBOX_IMAP_USERNAME=receipts@mail.example.com
RECEIPT_INBOX_IMAP_PASSWORD=...
# Optional
RECEIPT_INBOX_IMAP_MAILBOX=INBOX
RECEIPT_INBOX_IMAP_SSL=true      # false only for a server on your own network
RECEIPT_INBOX_IMAP_KEEP=false    # true marks mail as read instead of deleting it
```

The worker container needs an outbound connection to the IMAP server.

## Option 2: A mail service (Action Mailbox ingress)

Sure uses Rails Action Mailbox. Point your mail service's inbound webhook at
Sure and name it in `ACTION_MAILBOX_INGRESS`:

| Service | `ACTION_MAILBOX_INGRESS` | Credential | Webhook URL |
|---|---|---|---|
| Postmark | `postmark` | `RAILS_INBOUND_EMAIL_PASSWORD` | `https://actionmailbox:PASSWORD@your-sure-host/rails/action_mailbox/postmark/inbound_emails` (with "Include raw email content") |
| Mailgun | `mailgun` | `MAILGUN_INGRESS_SIGNING_KEY` | `https://your-sure-host/rails/action_mailbox/mailgun/inbound_emails/mime` |
| SendGrid | `sendgrid` | `RAILS_INBOUND_EMAIL_PASSWORD` | `https://actionmailbox:PASSWORD@your-sure-host/rails/action_mailbox/sendgrid/inbound_emails` (with "Post the raw, full MIME message") |
| Mandrill | `mandrill` | `MANDRILL_INGRESS_API_KEY` | `https://your-sure-host/rails/action_mailbox/mandrill/inbound_emails` |
| Postfix, Exim, Qmail | `relay` | `RAILS_INBOUND_EMAIL_PASSWORD` | see the [Action Mailbox guide](https://guides.rubyonrails.org/action_mailbox_basics.html) |

Without `ACTION_MAILBOX_INGRESS`, these endpoints answer 404. Both options can
run at the same time.

## Privacy

Sure keeps a received mail only until its attachments are stored as receipts
and deletes it after an hour. Refused mail gets no reply, so a forged sender
never receives mail from Sure.
