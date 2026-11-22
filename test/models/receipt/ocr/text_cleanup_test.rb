require "test_helper"

class Receipt::Ocr::TextCleanupTest < ActiveSupport::TestCase
  test "reads a letter O inside an amount as a zero" do
    assert_equal "SUMME 12,30", cleanup("SUMME 12,3O")
    assert_equal "Total 100.05", cleanup("Total 1OO.O5")
  end

  test "joins decimals split off by a space" do
    assert_equal "SUMME EUR 12,30", cleanup("SUMME EUR 12, 30")
    assert_equal "Total 4.70 USD", cleanup("Total 4. 70 USD")
  end

  test "leaves words and other numbers alone" do
    text = "BOOT OO.OO Ostbahnhof 2026-11-20 Tel. 030 1234 Artikel 3, 125 g"
    assert_equal text, cleanup(text)
  end

  private
    def cleanup(text)
      Receipt::Ocr::TextCleanup.call(text)
    end
end
