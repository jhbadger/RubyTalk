# frozen_string_literal: true

# A vertical scroll bar for views that show part of something longer (ListView, TextView). The including
# view says how much there is and how much shows by defining:
#
#   scroll_total      how many lines (rows) there are
#   scroll_visible    how many fit
#   scroll_top        the first one showing
#   scroll_top=(n)    scroll so that n is first (clamping it)
#
# and calls draw_scrollbar from display_view. The bar sits at the view's right edge and only appears
# when there is more than fits.
module Scrollable
  SCROLLBAR_WIDTH = 8

  def scrollbar_visible?
    scroll_visible.positive? && scroll_total > scroll_visible
  end

  def scrollbar_rect
    Rectangle.from(width - SCROLLBAR_WIDTH - 1, 1, SCROLLBAR_WIDTH, [height - 2, 0].max)
  end

  def in_scrollbar?(point)
    scrollbar_visible? && scrollbar_rect.contains?(point)
  end

  # The largest useful scroll_top.
  def max_scroll_top
    [scroll_total - scroll_visible, 0].max
  end

  def thumb_rect
    track = scrollbar_rect
    size = (track.height * scroll_visible.to_f / scroll_total).round.clamp([8, track.height].min, track.height)
    travel = track.height - size
    offset = max_scroll_top.zero? ? 0 : (travel * scroll_top.to_f / max_scroll_top).round
    Rectangle.from(track.left, track.top + offset, track.width, size)
  end

  # Scroll so that the thumb is centred on +point+ (view coordinates): for clicking and dragging the bar.
  def scroll_to_point(point)
    track = scrollbar_rect
    thumb = thumb_rect
    travel = track.height - thumb.height
    return if travel <= 0

    fraction = (point.y - (thumb.height / 2.0) - track.top) / travel
    self.scroll_top = (fraction.clamp(0.0, 1.0) * max_scroll_top).round
  end

  def draw_scrollbar(form)
    return unless scrollbar_visible?

    track = scrollbar_rect
    form.fill(track, Color.gray_level(0.9))
    form.border(track, 1, Color.gray)
    form.fill(thumb_rect.inset_by(1), Color.dark_gray)
  end
end
