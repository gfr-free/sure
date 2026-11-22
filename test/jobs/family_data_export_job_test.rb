require "test_helper"

class FamilyDataExportJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @export = @family.family_exports.create!
  end

  test "marks export as processing then completed" do
    assert_equal "pending", @export.status

    perform_enqueued_jobs do
      FamilyDataExportJob.perform_later(@export)
    end

    @export.reload
    assert_equal "completed", @export.status
    assert @export.export_file.attached?
  end

  test "an export with files puts the attachment files in the zip" do
    @export.update!(include_files: true)
    transaction = @family.transactions.first
    transaction.attachments.attach(io: StringIO.new("receipt bytes"), filename: "receipt.pdf", content_type: "application/pdf")

    perform_enqueued_jobs do
      FamilyDataExportJob.perform_later(@export)
    end

    @export.reload
    assert_equal "completed", @export.status
    Zip::File.open_buffer(StringIO.new(@export.export_file.download)) do |zip|
      manifest = JSON.parse(zip.read("attachments.json"))
      item = manifest["attachments"].find { |attachment| attachment["filename"] == "receipt.pdf" }

      assert manifest["binary_included"]
      assert_equal "receipt bytes", zip.read(item["path"])
    end
  end

  test "keeps an export alive while it writes files" do
    @export.update_columns(updated_at: 2.hours.ago)
    heartbeat = FamilyDataExportJob.new.send(:heartbeat, @export)

    heartbeat.call
    assert_operator @export.reload.updated_at, :<, 1.hour.ago

    travel FamilyDataExportJob::TOUCH_INTERVAL + 1.second do
      heartbeat.call
      assert_operator @export.reload.updated_at, :>, 1.minute.ago
    end
  end

  test "an export failed while it was written stays failed" do
    Family::DataExporter.any_instance.stubs(:generate_export).with do |_io|
      FamilyExport.where(id: @export.id).update_all(status: "failed")
      true
    end

    perform_enqueued_jobs do
      FamilyDataExportJob.perform_later(@export)
    end

    assert_equal "failed", @export.reload.status
  end

  test "does not restart an export in a terminal status" do
    @export.update_columns(status: "failed")

    Family::DataExporter.any_instance.expects(:generate_export).never

    perform_enqueued_jobs do
      FamilyDataExportJob.perform_later(@export)
    end

    assert_equal "failed", @export.reload.status
  end

  test "marks export as failed on error" do
    # Mock the exporter to raise an error
    Family::DataExporter.any_instance.stubs(:generate_export).raises(StandardError, "Export failed")

    perform_enqueued_jobs do
      FamilyDataExportJob.perform_later(@export)
    end

    @export.reload
    assert_equal "failed", @export.status
  end
end
