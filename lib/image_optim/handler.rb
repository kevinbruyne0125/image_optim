require 'image_optim/image_path'

class ImageOptim
  class Handler
    attr_reader :result
    def initialize(original)
      fail ArgumentError, 'original should respond to temp_path' unless original.respond_to?(:temp_path)

      @original = original
      @result = nil
    end

    def process
      @src ||= @original
      @dst ||= @original.temp_path

      if yield @src, @dst
        @result = @dst
        if @src == @original
          @src, @dst = @dst, nil
        else
          @src, @dst = @dst, @src
        end
      end
    end

    # Remove extra temp files
    def cleanup
      if @dst
        @dst.unlink
        @dst = nil
      end
    end
  end
end
