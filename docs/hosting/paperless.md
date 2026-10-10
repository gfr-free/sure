# Linking Paperless-ngx Documents

[Paperless-ngx](https://docs.paperless-ngx.com/) is a self-hosted document archive. Sure
can link receipts and invoices stored there to transactions. The files stay in
Paperless; Sure only stores the link and a few cached details (title, date,
correspondent, file type).

## 1. Create an API Token in Paperless

1. In Paperless, open your profile (top right) and create an **API Auth Token**.
2. Copy the token. Sure sends it as an `Authorization` header and stores it encrypted.

Sure only sees the documents the Paperless user behind the token may see.

## 2. Connect Sure

1. In Sure, go to **Settings > Paperless**.
2. Enter the Paperless address (for example `https://paperless.example.com`) and the token.
3. Save. Sure checks the connection and shows the server version or the error.

By default each member connects their own Paperless account. A family admin can switch
the family to one shared connection on the same page.

## 3. Link Documents

Open a transaction and use **Link from Paperless** in the Attachments section. The search
is prefilled with the transaction name and a date range around the transaction date.

## Private Network Addresses

The Paperless address is requested from Sure's server, so it could otherwise be used to
reach internal services. Sure therefore checks every address before it connects:

- **Strict check:** only HTTPS, and no private, loopback, link-local or other
  non-public addresses.
- **Private addresses allowed:** plain HTTP and private addresses (for example
  `http://192.168.1.20:8000` or `http://paperless:8000` in Docker) are accepted, but only
  for connections owned by a family admin, the shared family connection, and member
  connections that point to the same server an admin already connected. All other
  connections still get the strict check. The rule is checked when the connection is
  saved and again on every request, so it keeps holding after a role change.

Which of the two applies is set by `PAPERLESS_ALLOW_PRIVATE_HOSTS`:

| `PAPERLESS_ALLOW_PRIVATE_HOSTS` | Self-hosted (`SELF_HOSTED=true`) | Managed |
|---|---|---|
| not set (default) | private addresses allowed | strict check |
| `true` | private addresses allowed | private addresses allowed |
| `false` | strict check | strict check |

Set it to `false` on a self-hosted install that is shared with people you do not fully
trust, or whose server can reach internal services Paperless users should not reach. Set
it to `true` on a managed install only if Paperless runs in the same private network and
every family admin may reach that network from the server.
