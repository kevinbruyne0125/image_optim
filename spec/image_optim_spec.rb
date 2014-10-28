require 'spec_helper'
require 'image_optim'
require 'image_optim/cmd'
require 'tempfile'
require 'English'

describe ImageOptim do
  images_dir = ImageOptim::ImagePath.new(__FILE__).dirname / 'images'
  test_images = images_dir.glob('**/*.*').freeze

  helpers = Module.new do
    def temp_copy(image)
      image.temp_path.tap{ |path| image.copy(path) }
    end
  end
  include helpers
  extend helpers

  matcher :be_in_range do |expected|
    match{ |actual| expected.include?(actual) }
  end

  before do
    stub_const('Cmd', ImageOptim::Cmd)

    allow(ImageOptim::Config).to receive(:global).and_return({})
    allow(ImageOptim::Config).to receive(:local).and_return({})
  end

  describe 'workers' do
    they 'are ordered by run_order' do
      image_optim = ImageOptim.new
      original_klasses = ImageOptim::Worker.klasses
      formats = original_klasses.map do |klass|
        klass.new(image_optim, {}).image_formats
      end.flatten.uniq

      [
        original_klasses,
        original_klasses.to_a.reverse,
        original_klasses.to_a.shuffle,
      ].each do |klasses|
        expect(ImageOptim::Worker).to receive(:klasses).and_return(klasses)

        image_optim = ImageOptim.new

        formats.each do |format|
          path = ImageOptim::ImagePath.new("test.#{format}")
          expect(path).to receive(:format).and_return(format)

          workers = image_optim.workers_for_image(path)
          expect(workers).to eq(workers.sort_by.with_index do |worker, i|
            [worker.run_order, i]
          end)
        end
      end
    end
  end

  disable_all_workers = Hash[ImageOptim::Worker.klasses.map do |klass|
    [klass.bin_sym, false]
  end]

  ImageOptim::Worker.klasses.each do |worker_klass|
    describe "#{worker_klass.bin_sym} worker" do
      it 'optimizes at least one test image' do
        options = disable_all_workers.merge(worker_klass.bin_sym => true)
        image_optim = ImageOptim.new(options)
        expect(test_images.any? do |original|
          image_optim.optimize_image(temp_copy(original))
        end).to be true
      end
    end
  end

  describe :optimize_image do
    def flatten_animation(image)
      if image.format == :gif
        flattened = image.temp_path
        flatten_command = %W[
          convert
          #{image.to_s.shellescape}
          -coalesce
          -append
          #{flattened.to_s.shellescape}
        ].join(' ')
        expect(Cmd.run(flatten_command)).to be_truthy
        flattened
      else
        image
      end
    end

    def nrmse(image_a, image_b)
      coalesce_a = flatten_animation(image_a)
      coalesce_b = flatten_animation(image_b)
      nrmse_command = %W[
        compare
        -metric RMSE
        #{coalesce_a.to_s.shellescape}
        #{coalesce_b.to_s.shellescape}
        /dev/null
        2>&1
      ].join(' ')
      output = Cmd.capture(nrmse_command)
      if [0, 1].include?($CHILD_STATUS.exitstatus)
        output[/\((\d+(\.\d+)?)\)/, 1].to_f
      else
        fail "compare #{image_a} with #{image_b} failed with `#{output}`"
      end
    end

    define :have_same_data_as do |expected|
      match{ |actual| actual.binread == expected.binread }
    end

    define :have_size do
      match{ |actual| actual.size? }
    end

    define :be_smaller_than do |expected|
      match{ |actual| actual.size < expected.size }
    end

    define :be_pixel_identical_to do |expected|
      match do |actual|
        @diff = nrmse(actual, expected)
        @diff == 0
      end
      failure_message do |actual|
        "expected #{actual} to be pixel identical to #{expected}, got "\
            "normalized root-mean-square error of #{@diff}"
      end
    end

    describe 'optimizing images' do
      rotated = images_dir / 'orient/original.jpg'
      rotate_images = images_dir.glob('orient/?.jpg')

      original_by_copy = Hash[test_images.map do |image|
        [temp_copy(image), image]
      end]
      copies = original_by_copy.keys

      ImageOptim.optimize_images(copies) do |copy, optimized|
        fail 'expected copy to not be nil' if copy.nil?
        original = original_by_copy[copy]

        it "optimizes #{original}" do
          expect(copy).to have_same_data_as(original)

          expect(optimized).not_to be_nil
          expect(optimized).to be_a(ImageOptim::ImagePath::Optimized)
          expect(optimized).to have_size
          expect(optimized).to be_smaller_than(original)
          expect(optimized).not_to have_same_data_as(original)

          compare_to = rotate_images.include?(original) ? rotated : original
          expect(optimized).to be_pixel_identical_to(compare_to)
        end
      end
    end

    it 'ignores text file' do
      original = ImageOptim::ImagePath.new(__FILE__)
      copy = temp_copy(original)

      expect(Tempfile).not_to receive(:new)
      optimized_image = ImageOptim.optimize_image(copy)
      expect(optimized_image).to be_nil
      expect(copy.read).to eq(original.read)
    end

    {
      :png => "\211PNG\r\n\032\n",
      :jpeg => "\377\330",
    }.each do |type, data|
      it "ingores broken #{type}" do
        path = FSPath.temp_file_path
        path.write(data)
        expect(ImageOptim::ImageMeta).to receive(:warn)
        expect(ImageOptim.optimize_image(path)).to be_nil
      end
    end
  end

  describe :optimize_image! do
    it 'optimizes image and replaces original' do
      original = double
      optimized = double(:original_size => 12_345)
      optimized_wrap = double
      image_optim = ImageOptim.new

      allow(ImageOptim::ImagePath).to receive(:convert).
        with(original).and_return(original)

      expect(image_optim).to receive(:optimize_image).
        with(original).and_return(optimized)
      expect(optimized).to receive(:replace).with(original)
      expect(ImageOptim::ImagePath::Optimized).to receive(:new).
        with(original, 12_345).and_return(optimized_wrap)

      expect(image_optim.optimize_image!(original)).to eq(optimized_wrap)
    end

    it 'returns nil if optimization fails' do
      original = double
      image_optim = ImageOptim.new

      allow(ImageOptim::ImagePath).to receive(:convert).
        with(original).and_return(original)

      expect(image_optim).to receive(:optimize_image).
        with(original).and_return(nil)
      expect(ImageOptim::ImagePath::Optimized).not_to receive(:new)

      expect(image_optim.optimize_image!(original)).to eq(nil)
    end
  end

  describe :optimize_image_data do
    it 'create temp file, optimizes image and returns data' do
      data = double
      temp = double(:path => double)
      optimized = double
      optimized_data = double
      image_optim = ImageOptim.new

      allow(ImageOptim::ImageMeta).to receive(:for_data).
        with(data).and_return(double(:format => 'xxx'))

      expect(ImageOptim::ImagePath).to receive(:temp_file).and_yield(temp)
      expect(temp).to receive(:binmode)
      expect(temp).to receive(:write).with(data)
      expect(temp).to receive(:close)
      expect(image_optim).to receive(:optimize_image).
        with(temp.path).and_return(optimized)
      expect(optimized).to receive(:binread).and_return(optimized_data)

      expect(image_optim.optimize_image_data(data)).to eq(optimized_data)
    end

    it 'returns nil if optimization fails' do
      data = double
      temp = double(:path => double)
      image_optim = ImageOptim.new

      allow(ImageOptim::ImageMeta).to receive(:for_data).
        with(data).and_return(double(:format => 'xxx'))

      expect(ImageOptim::ImagePath).to receive(:temp_file).and_yield(temp)
      expect(temp).to receive(:binmode)
      expect(temp).to receive(:write).with(data)
      expect(temp).to receive(:close)
      expect(image_optim).to receive(:optimize_image).
        with(temp.path).and_return(nil)

      expect(image_optim.optimize_image_data(data)).to eq(nil)
    end

    it 'returns nil if format can\'t be detected' do
      data = double
      image_optim = ImageOptim.new

      allow(ImageOptim::ImageMeta).to receive(:for_data).
        with(data).and_return(double(:format => nil))

      expect(ImageOptim::ImagePath).not_to receive(:temp_file)
      expect(image_optim).not_to receive(:optimize_image)

      expect(image_optim.optimize_image_data(data)).to eq(nil)
    end
  end

  describe 'optimize multiple' do
    %w[
      optimize_images
      optimize_images!
      optimize_images_data
    ].each do |list_method|
      describe list_method do
        method = list_method.sub('images', 'image')
        describe 'without block' do
          it 'optimizes images and returns array of results' do
            image_optim = ImageOptim.new
            results = test_images.map do |src|
              dst = double
              expect(image_optim).to receive(method).with(src).and_return(dst)
              [src, dst]
            end
            expect(image_optim.send(list_method, test_images)).to eq(results)
          end
        end

        describe 'given block' do
          it 'optimizes images, yields path and result for each and '\
              'returns array of yield results' do
            image_optim = ImageOptim.new
            results = test_images.map do |src|
              dst = double
              expect(image_optim).to receive(method).with(src).and_return(dst)
              [src, dst, :test]
            end
            expect(image_optim.send(list_method, test_images) do |src, dst|
              [src, dst, :test]
            end).to eq(results)
          end
        end
      end
    end
  end
end
