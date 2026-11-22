class FamilyDataExportJob < ApplicationJob
  queue_as :default

  TOUCH_INTERVAL = 1.minute

  def perform(family_export)
    # Terminal statuses own the record: a redelivered job must not restart a
    # completed export, and one the reaper already failed stays failed.
    # A processing export is allowed through — graceful worker shutdowns
    # re-enqueue in-flight jobs, and that redelivery is what completes it.
    return if family_export.completed? || family_export.failed?

    family_export.update!(status: :processing)

    exporter = Family::DataExporter.new(
      family_export.family,
      include_files: family_export.include_files?,
      on_progress: heartbeat(family_export)
    )

    # A temp file rather than memory: with attachment files the ZIP can get large.
    Tempfile.create([ "sure_export", ".zip" ], binmode: true) do |file|
      exporter.generate_export(file)
      file.rewind

      family_export.export_file.attach(
        io: file,
        filename: family_export.filename,
        content_type: "application/zip"
      )
    end

    # The reaper or a manual cancel may have failed the export meanwhile; that
    # status stands.
    family_export.with_lock do
      family_export.update!(status: :completed) if family_export.processing?
    end
  rescue => e
    Rails.logger.error "Family export failed: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    family_export.update!(status: :failed)
  end

  private
    # Copying many attachment files can take long. Touching the export keeps it
    # from looking lost (FamilyExport::PRESUMED_LOST_AFTER, STUCK_AFTER) while it
    # is still being written.
    def heartbeat(family_export)
      last_touch = Time.current

      lambda do
        next if Time.current - last_touch < TOUCH_INTERVAL

        family_export.touch
        last_touch = Time.current
      end
    end
end
