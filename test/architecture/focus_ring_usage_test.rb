# frozen_string_literal: true

require "test_helper"

class FocusRingUsageTest < ActiveSupport::TestCase
  SOURCE_GLOBS = %w[
    app/views/**/*.erb
    app/components/**/*.{erb,rb}
    app/helpers/**/*.rb
    app/javascript/**/*.js
  ].freeze

  # Matches colored or sized focus rings (`focus:ring-2`, `focus-visible:ring-gray-900`,
  # `focus-within:ring-secondary`, `focus:ring-offset-2`). `focus:ring-0` stays allowed:
  # it neutralizes the @tailwindcss/forms focus box-shadow on native inputs so only
  # the canonical outline shows.
  BESPOKE_FOCUS_RING = /(?<![\w-])focus(?:-visible|-within)?:ring(?!-0(?![\w\/.-]))(?:-[\w\/.\[\]-]+)?/

  test "keyboard focus uses the canonical focus-ring classes" do
    violations = []

    SOURCE_GLOBS.flat_map { |glob| Dir.glob(Rails.root.join(glob).to_s) }.sort.each do |path|
      File.readlines(path).each.with_index(1) do |line, line_number|
        next unless line.match?(BESPOKE_FOCUS_RING)

        relative_path = Pathname.new(path).relative_path_from(Rails.root)
        violations << "#{relative_path}:#{line_number}: #{line.strip}"
      end
    end

    assert_empty violations, <<~MESSAGE
      Use `focus-ring` (or `focus-ring-within` on a wrapper) instead of bespoke focus:ring-* classes.
      See app/assets/tailwind/sure-design-system/components.css.

      #{violations.join("\n")}
    MESSAGE
  end
end
