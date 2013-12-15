require 'fspath'
require 'image_size'

class ImageOptim
  class ImagePath < FSPath
    class Optimized < self
      def initialize(path, original_or_size = nil)
        super(path)
        if original_or_size
          if original_or_size.is_a?(Integer)
            @original = self
            @original_size = original_or_size
          else
            @original = ImagePath.new(original_or_size)
            @original_size = @original.size
          end
        end
      end

      # Original path, use original_size to get its size as original can be overwritten
      attr_reader :original

      # Stored size of original
      attr_reader :original_size
    end

    # Get temp path for this file with same extension
    def temp_path(*args, &block)
      ext = extname
      self.class.temp_file_path([basename(ext), ext], *args, &block)
    end

    # Copy file to dest preserving attributes
    def copy(dst)
      FileUtils.copy_file(self, dst, true)
    end

    # Atomic replace src with self
    def replace(src)
      src = self.class.new(src)
      src.temp_path(src.dirname) do |temp|
        src.copy(temp)
        temp.write(read)
        temp.rename(src.to_s)
      end
    end

    # Get format using ImageSize
    def format
      open{ |f| ImageSize.new(f) }.format
    end
  end
end
