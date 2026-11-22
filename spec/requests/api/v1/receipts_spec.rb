# frozen_string_literal: true

require 'swagger_helper'
require Rails.root.join('test/support/receipt_pdf_helper')

RSpec.describe 'API V1 Receipts', type: :request do
  include ReceiptPdfHelper

  let(:family) do
    Family.create!(name: 'API Family', currency: 'USD', locale: 'en', date_format: '%m-%d-%Y')
  end
  let(:user) do
    family.users.create!(
      email: 'api-user@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      role: 'admin',
      preferences: { 'preview_features_enabled' => true }
    )
  end
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'API Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'web'
    )
  end
  let(:'X-Api-Key') { api_key.plain_key }
  let(:guest) do
    family.users.create!(
      email: 'api-guest@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      role: 'guest',
      preferences: { 'preview_features_enabled' => true }
    )
  end
  let(:guest_api_key) do
    ApiKey.create!(user: guest, name: 'Guest Docs Key', key: ApiKey.generate_secure_key, scopes: %w[read_write], source: 'web')
  end
  let(:account) do
    Account.create!(
      family: family,
      owner: user,
      name: 'Test Checking',
      balance: 1000,
      currency: 'USD',
      accountable: Depository.new
    )
  end
  let(:entry) do
    account.entries.create!(name: 'Corner Shop', date: Date.new(2026, 11, 1), amount: 7.25, currency: 'USD', entryable: Transaction.new)
  end

  def receipt_file(text = 'Total 7.25', filename: 'receipt.pdf')
    uploaded_receipt(receipt_pdf([ 'Corner Shop', text ]), filename: filename)
  end

  let!(:receipt) do
    Receipt.create_from_upload!(family: family, user: user, file: receipt_file('Total 7.25 USD')).tap do |receipt|
      receipt.update!(merchant_name: 'Corner Shop', date: Date.new(2026, 11, 1), amount: 7.25, currency: 'USD', extraction_status: 'completed')
    end
  end

  path '/api/v1/receipts' do
    get 'List your receipts' do
      description 'Lists receipts the caller uploaded, newest first. Receipts are private to their uploader. ' \
                  'Requires an admin or member with preview features enabled.'
      tags 'Receipts'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      parameter name: :status, in: :query, required: false,
                schema: { type: :string, enum: %w[reading open linked dismissed] },
                description: 'Same values as a receipt\'s status: reading (fields still being read), open, linked or dismissed'
      parameter name: :extraction_status, in: :query, required: false,
                schema: { type: :string, enum: %w[pending completed failed] }
      parameter name: :content_sha256, in: :query, type: :string, required: false,
                description: 'Find the receipt for a file by its SHA-256 (hex)'
      parameter name: :page, in: :query, type: :integer, required: false, description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false, description: 'Items per page (default: 25, max: 100)'

      response '200', 'receipts listed' do
        schema '$ref' => '#/components/schemas/ReceiptCollection'
        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { nil }
        run_test!
      end

      response '403', 'guest, or preview features not enabled' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { guest_api_key.plain_key }
        run_test!
      end

      response '422', 'invalid filter' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:status) { 'lost' }
        run_test!
      end
    end

    post 'Upload a receipt' do
      description 'Stores a photo (JPEG, PNG, GIF, WebP) or PDF of a receipt, max 10 MB, and reads its merchant, date, ' \
                  'amount and currency in the background (status "reading" until done). Uploading a file the caller ' \
                  'already uploaded returns the existing receipt with meta.duplicate = true.'
      tags 'Receipts'
      security [ { apiKeyAuth: [] } ]
      consumes 'multipart/form-data'
      produces 'application/json'

      parameter name: :file, in: :formData, required: true,
                description: 'Receipt photo or PDF',
                schema: {
                  type: :object,
                  required: [ 'file' ],
                  properties: { file: { type: :string, format: :binary } }
                }

      response '201', 'receipt stored' do
        schema '$ref' => '#/components/schemas/ReceiptResponse'
        let(:file) { receipt_file('Total 3.80 USD', filename: 'bakery.pdf') }
        run_test!
      end

      response '200', 'file already uploaded' do
        schema '$ref' => '#/components/schemas/ReceiptResponse'
        let(:file) { receipt_file('Total 7.25 USD') }
        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { nil }
        let(:file) { receipt_file }
        run_test!
      end

      response '403', 'guest, API key without write scope, or preview features not enabled' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { guest_api_key.plain_key }
        let(:file) { receipt_file }
        run_test!
      end

      response '422', 'missing or unsupported file' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:file) { nil }
        run_test!
      end
    end
  end

  path '/api/v1/receipts/{id}' do
    parameter name: :id, in: :path, type: :string, format: :uuid, required: true

    get 'Show a receipt' do
      tags 'Receipts'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'receipt found' do
        schema '$ref' => '#/components/schemas/ReceiptResponse'
        let(:id) { receipt.id }
        run_test!
      end

      response '404', 'receipt not found, or uploaded by someone else' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:id) { SecureRandom.uuid }
        run_test!
      end
    end

    patch 'Correct the fields read from a receipt' do
      description 'Sets merchant_name, date, amount or currency. Each field sent is marked as entered by hand, ' \
                  'so reading the receipt again keeps it. null clears a field.'
      tags 'Receipts'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          merchant_name: { type: :string, nullable: true },
          date: { type: :string, format: :date, nullable: true },
          amount: { type: :string, nullable: true, description: 'Positive decimal' },
          currency: { type: :string, nullable: true, description: 'ISO 4217 code' }
        }
      }

      response '200', 'receipt updated' do
        schema '$ref' => '#/components/schemas/ReceiptResponse'
        let(:id) { receipt.id }
        let(:body) { { merchant_name: 'Corner Shop Ltd', amount: '7.50' } }
        run_test!
      end

      response '422', 'unreadable value' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:id) { receipt.id }
        let(:body) { { date: '01.11.2026' } }
        run_test!
      end
    end

    delete 'Delete a receipt' do
      description 'Deletes the receipt and its file. A copy already attached to a transaction stays there.'
      tags 'Receipts'
      security [ { apiKeyAuth: [] } ]

      response '204', 'receipt deleted' do
        let(:id) { receipt.id }
        run_test!
      end

      response '404', 'receipt not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:id) { SecureRandom.uuid }
        run_test!
      end
    end
  end

  path '/api/v1/receipts/{id}/file' do
    parameter name: :id, in: :path, type: :string, format: :uuid, required: true

    get 'Download the receipt file' do
      tags 'Receipts'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      parameter name: :disposition, in: :query, required: false,
                schema: { type: :string, enum: %w[inline attachment] }

      response '200', 'receipt file' do
        # The file is streamed with its own content type; only the error responses are JSON.
        metadata[:response][:content] = {
          'application/octet-stream' => { schema: { type: :string, format: :binary } }
        }
        let(:id) { receipt.id }
        run_test!
      end

      response '404', 'receipt not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:id) { SecureRandom.uuid }
        run_test!
      end
    end
  end

  path '/api/v1/receipts/{id}/candidates' do
    parameter name: :id, in: :path, type: :string, format: :uuid, required: true

    get 'List transactions the receipt may belong to' do
      description 'Up to 20 transactions on accounts the caller can write to, within 30 days of the receipt date ' \
                  'and, when the amount is known, for exactly that amount. Nearest date first.'
      tags 'Receipts'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'candidates listed' do
        schema '$ref' => '#/components/schemas/ReceiptCandidateCollection'
        let(:id) do
          entry
          receipt.id
        end
        run_test!
      end
    end
  end

  path '/api/v1/receipts/{id}/link' do
    parameter name: :id, in: :path, type: :string, format: :uuid, required: true

    post 'Link a receipt to a transaction' do
      description 'Attaches a copy of the file to the transaction. Needs write access to its account.'
      tags 'Receipts'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[transaction_id],
        properties: { transaction_id: { type: :string, format: :uuid } }
      }

      response '200', 'receipt linked' do
        schema '$ref' => '#/components/schemas/ReceiptResponse'
        let(:id) { receipt.id }
        let(:body) { { transaction_id: entry.transaction.id } }
        run_test!
      end

      response '404', 'transaction not found or not writable' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:id) { receipt.id }
        let(:body) { { transaction_id: SecureRandom.uuid } }
        run_test!
      end

      response '422', 'receipt already linked, or the transaction has too many attachments' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:id) do
          receipt.link_to!(entry.transaction, user: user)
          receipt.id
        end
        let(:body) { { transaction_id: entry.transaction.id } }
        run_test!
      end
    end
  end

  path '/api/v1/receipts/{id}/create_transaction' do
    parameter name: :id, in: :path, type: :string, format: :uuid, required: true

    post 'Record a receipt as a new transaction' do
      description 'Creates an expense on the account and links the receipt to it. Values left out are taken from the receipt.'
      tags 'Receipts'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[account_id],
        properties: {
          account_id: { type: :string, format: :uuid, description: 'Account the caller can write to' },
          name: { type: :string },
          date: { type: :string, format: :date },
          amount: { type: :string, description: 'Positive decimal' },
          currency: { type: :string }
        }
      }

      response '201', 'transaction created and linked' do
        schema '$ref' => '#/components/schemas/ReceiptResponse'
        let(:id) { receipt.id }
        let(:body) { { account_id: account.id } }
        run_test!
      end

      response '404', 'account not found or not writable' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:id) { receipt.id }
        let(:body) { { account_id: SecureRandom.uuid } }
        run_test!
      end

      response '422', 'no usable date or amount' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:id) { receipt.id }
        let(:body) { { account_id: account.id, amount: 'abc' } }
        run_test!
      end
    end
  end

  path '/api/v1/receipts/{id}/dismiss' do
    parameter name: :id, in: :path, type: :string, format: :uuid, required: true

    post 'Dismiss a receipt' do
      description 'Moves a receipt that needs no transaction out of the open list.'
      tags 'Receipts'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'receipt dismissed' do
        schema '$ref' => '#/components/schemas/ReceiptResponse'
        let(:id) { receipt.id }
        run_test!
      end
    end
  end

  path '/api/v1/receipts/{id}/reopen' do
    parameter name: :id, in: :path, type: :string, format: :uuid, required: true

    post 'Reopen a dismissed receipt' do
      tags 'Receipts'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'receipt reopened' do
        schema '$ref' => '#/components/schemas/ReceiptResponse'
        let(:id) do
          receipt.dismiss!
          receipt.id
        end
        run_test!
      end
    end
  end
end
