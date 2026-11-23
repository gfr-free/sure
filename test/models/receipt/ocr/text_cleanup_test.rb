require "test_helper"

class Receipt::Ocr::TextCleanupTest < ActiveSupport::TestCase
  test "reads a letter O inside an amount as a zero" do
    assert_equal "SUMME 12,30", cleanup("SUMME 12,3O")
    assert_equal "Total 100.05", cleanup("Total 1OO.O5")
  end

  test "joins decimals split off by a space" do
    assert_equal "SUMME EUR 12,30", cleanup("SUMME EUR 12, 30")
    assert_equal "Total 4.70 USD", cleanup("Total 4. 70 USD")
    assert_equal "Brot\nSUMME 6,75\n", cleanup("Brot\nSUMME 6, 75\n")
    assert_equal "SUMME EUR 12,30", cleanup("SUMME EUR 12, 3O")
  end

  test "leaves words and other numbers alone" do
    [ "BOOT OO.OO Ostbahnhof 2026-11-20 Tel. 030 1234 Artikel 3, 125 g", "Kasse 2, 15:43 EUR", "Tisch 3, 12",
      "Art. 5, 10 Stk" ].each do |text|
      assert_equal text, cleanup(text)
    end
  end

  private
    def cleanup(text)
      Receipt::Ocr::TextCleanup.call(text)
    end
end
