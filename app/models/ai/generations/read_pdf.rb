# What an uploaded PDF is and what it says: its document type, a summary and the
# statement's key figures, from the first batch of its pages.
class Ai::Generations::ReadPdf < Ai::Generation
  include Ai::PdfReading::Pages

  # The terms of an ongoing consumer contract, kept so the import page can offer to record it.
  # Contract, policy and customer numbers are never asked for.
  CONTRACT_TERMS = {
    type: %w[object null],
    properties: {
      name: { type: %w[string null] }, provider: { type: %w[string null] },
      kind: { type: %w[string null], enum: Contract.kinds.keys + [ nil ] },
      started_on: { type: %w[string null] }, minimum_term_months: { type: %w[integer null] },
      notice_period_value: { type: %w[integer null] },
      notice_period_unit: { type: %w[string null], enum: [ "days", "weeks", "months", nil ] },
      notice_anchor: { type: %w[string null], enum: [ "end_of_term", "end_of_month", "any_day", nil ] },
      renewal_period_months: { type: %w[integer null] }, renewal_anchor_on: { type: %w[string null] },
      ends_on: { type: %w[string null] }, premium_amount: { type: %w[number null] },
      premium_frequency: { type: %w[string null], enum: [ "monthly", "quarterly", "semiannual", "annual", nil ] }
    },
    required: %w[name provider kind started_on minimum_term_months notice_period_value notice_period_unit notice_anchor
                 renewal_period_months renewal_anchor_on ends_on premium_amount premium_frequency],
    additionalProperties: false
  }.freeze

  prompt "read_pdf"
  schema_name "document_analysis"

  schema({
    type: "object",
    properties: {
      document_type: { type: %w[string null], enum: Import::DOCUMENT_TYPES + [ nil ] },
      summary: { type: %w[string null] },
      extracted_data: {
        type: %w[object null],
        properties: {
          institution_name: NULLABLE_STRING, statement_period_start: NULLABLE_STRING, statement_period_end: NULLABLE_STRING,
          transaction_count: { type: %w[integer null] }, opening_balance: NULLABLE_NUMBER, closing_balance: NULLABLE_NUMBER,
          currency: NULLABLE_STRING, account_holder: NULLABLE_STRING, contract: CONTRACT_TERMS
        },
        required: %w[institution_name statement_period_start statement_period_end transaction_count opening_balance
                     closing_balance currency account_holder contract],
        additionalProperties: false
      }
    },
    required: %w[document_type summary extracted_data],
    additionalProperties: false
  }.freeze)

  # A statement page answered after a cover page is the answer to keep: splitting a batch can
  # classify both, and by then there is no retry left. No answer at all (no slice fitted) is
  # unusable, so Auto reads another way rather than classify the file as nothing.
  def merge_values(values)
    values.find { Ai::PdfReading::STATEMENT_TYPES.include?(_1[:document_type].to_s) } || values.first ||
      raise(Ai::Error::InvalidOutput, "no batch of the document was answered")
  end
end
