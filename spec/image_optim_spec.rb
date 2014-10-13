require 'spec_helper'
require 'image_optim'
require 'image_optim/cmd'
require 'tempfile'

describe ImageOptim do
  test_images = ImageOptim::ImagePath.new(__FILE__).dirname.
    glob('images/**/*.*').freeze

  def temp_copy(image)
    image.temp_path.tap{ |path| image.copy(path) }
  end

  matcher :be_in_range do |expected|
    match{ |actual| expected.include?(actual) }
  end

  before do
    stub_const('Cmd', ImageOptim::Cmd)

    allow(ImageOptim::Config).to receive(:global).and_return({})
    allow(ImageOptim::Config).to receive(:local).and_return({})
  end

  describe 'workers' do
    it 'is ordered by run_order' do
      image_optim = ImageOptim.new
      original_klasses = ImageOptim::Worker.klasses
      formats = original_klasses.map do |klass|
        klass.new(image_optim, {}).image_formats
      end.flatten.uniq

      [
        original_klasses,
        original_klasses.reverse,
        original_klasses.shuffle,
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

  describe 'worker' do
    base_options = Hash[ImageOptim::Worker.klasses.map do |klass|
      [klass.bin_sym, false]
    end]

    ImageOptim::Worker.klasses.each do |worker_klass|
      describe worker_klass.bin_sym do
        it 'optimizes at least one test image' do
          options = base_options.merge(worker_klass.bin_sym => true)
          image_optim = ImageOptim.new(options)
          expect(test_images.any? do |original|
            image_optim.optimize_image(temp_copy(original))
          end).to be true
        end
      end
    end
  end

  describe 'isolated' do
    def expect_tempfile(expected)
      count = 0
      original_new = FSPath::Tempfile.method(:new)
      allow(FSPath::Tempfile).to receive(:new) do |*args|
        count += 1
        original_new.call(*args)
      end

      yield

      if expected.is_a?(Range)
        expect(count).to be_in_range(expected)
      else
        expect(count).to eq(expected)
      end
    end

    describe 'optimize' do
      test_images.each do |original|
        it "optimizes #{original}" do
          copy = temp_copy(original)

          image_optim = ImageOptim.new

          multiple_workers = image_optim.workers_for_image(original).length > 1
          expect_tempfile(multiple_workers ? 1..2 : 1) do
            optimized_image = image_optim.optimize_image(copy)
            expect(optimized_image).to be_a(ImageOptim::ImagePath::Optimized)
            expect(optimized_image.size).to be_in_range(1...original.size)
            expect(optimized_image.read).not_to eq(original.read)
            expect(copy.read).to eq(original.read)
          end
        end
      end
    end

    describe 'optimize in place' do
      test_images.each do |original|
        it "optimizes #{original}" do
          copy = temp_copy(original)

          image_optim = ImageOptim.new

          multiple_workers = image_optim.workers_for_image(original).length > 1
          expect_tempfile(multiple_workers ? 2..3 : 2) do
            expect(image_optim.optimize_image!(copy)).to be_truthy
            expect(copy.size).to be_in_range(1...original.size)
            expect(copy.read).not_to eq(original.read)
          end
        end
      end
    end

    describe 'optimize image data' do
      test_images.each do |original|
        it "optimizes #{original}" do
          image_optim = ImageOptim.new
          optimized_data = image_optim.optimize_image_data(original.read)
          expect(optimized_data).not_to be_nil

          expected_path = image_optim.optimize_image(temp_copy(original))
          expect(optimized_data).to eq(expected_path.open('rb', &:read))

          expect(image_optim.optimize_image_data(optimized_data)).to be_nil
        end
      end
    end
  end

  describe 'unsupported' do
    let(:original){ ImageOptim::ImagePath.new(__FILE__) }

    it 'ignores' do
      copy = temp_copy(original)

      expect(Tempfile).not_to receive(:new)
      optimized_image = ImageOptim.optimize_image(copy)
      expect(optimized_image).to be_nil
      expect(copy.read).to eq(original.read)
    end

    it 'ignores in place' do
      copy = temp_copy(original)

      expect(Tempfile).not_to receive(:new)
      expect(ImageOptim.optimize_image!(copy)).not_to be_truthy
      expect(copy.read).to eq(original.read)
    end

    {
      :png => "\211PNG\r\n\032\n",
      :jpeg => "\377\330",
    }.each do |type, data|
      describe "broken #{type}" do
        before do
          expect(ImageOptim::ImageMeta).to receive(:warn)
        end

        it 'ignores path' do
          path = FSPath.temp_file_path
          path.write(data)
          expect(ImageOptim.optimize_image(path)).to be_nil
        end

        it 'ignores data' do
          expect(ImageOptim.optimize_image_data(data)).to be_nil
        end
      end
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

  describe 'losslessness' do
    images_dir = ImageOptim::ImagePath.new(__FILE__).dirname / 'images'
    rotated = images_dir / 'orient/original.jpg'
    rotate_images = images_dir.glob('orient/?.jpg')

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

    def check_lossless_optimization(original, optimized)
      expect(optimized).not_to be_nil
      original = flatten_animation(original)
      optimized = flatten_animation(optimized)
      nrmse_command = %W[
        compare
        -metric RMSE
        #{original.to_s.shellescape}
        #{optimized.to_s.shellescape}
        /dev/null
        2>&1
      ].join(' ')
      nrmse = Cmd.capture(nrmse_command)[/\((\d+(\.\d+)?)\)/, 1]
      expect(nrmse).not_to be_nil
      expect(nrmse.to_f).to eq(0)
    end

    rotate_images.each do |image|
      it "rotates and optimizes #{image} losslessly" do
        check_lossless_optimization(rotated, ImageOptim.optimize_image(image))
      end
    end

    (test_images - rotate_images).each do |image|
      it "optimizes #{image} losslessly" do
        check_lossless_optimization(image, ImageOptim.optimize_image(image))
      end
    end
  end
end
