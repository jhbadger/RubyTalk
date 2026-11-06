# frozen_string_literal: true

# The text clipboard used by cut, copy and paste in text views. By default it is just a string in memory;
# the Tk windows swap in the system clipboard, so text copied in RubyTalk can be pasted elsewhere and
# the other way round.
#
#   Clipboard.text = 'hello'
#   Clipboard.text            # "hello"
module Clipboard
  class << self
    # An object with #get and #set(text) that holds the text (the Tk layer sets one); nil keeps it in memory.
    attr_accessor :backend

    def text
      backend ? backend.get.to_s : @text.to_s
    end

    def text=(string)
      if backend
        backend.set(string.to_s)
      else
        @text = string.to_s
      end
    end
  end
end
