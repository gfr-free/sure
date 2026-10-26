module PagesHelper
  # Names of the categories the outflows donut leaves out because refunds or
  # income cancel out their spending, as a sentence of transaction links.
  def outflows_offset_category_links(offset_categories)
    links = offset_categories.map do |category|
      if category[:clickable]
        link_to category[:name], category[:transactions_path],
          class: "font-medium text-primary hover:underline",
          data: { turbo_frame: "_top", turbo_prefetch: false }
      else
        tag.span(category[:name], class: "font-medium text-primary")
      end
    end

    to_sentence(links)
  end
end
