require "time"

require "rubygems"
require "maruku"
require "redcloth"

module Nesta
  class FileModel
    FORMATS = [:mdown, :haml, :textile]
    @@cache = {}

    attr_reader :filename, :mtime

    def self.model_path(basename = nil)
      Nesta::Config.content_path(basename)
    end

    def self.find_all
      file_pattern = File.join(model_path, "**", "*.{#{FORMATS.join(',')}}")
      Dir.glob(file_pattern).map do |path|
        relative = path.sub("#{model_path}/", "")
        load(relative.sub(/\.(#{FORMATS.join('|')})/, ""))
      end
    end

    def self.needs_loading?(path, filename)
      @@cache[path].nil? || File.mtime(filename) > @@cache[path].mtime
    end

    def self.load(path)
      FORMATS.each do |format|
        [path, File.join(path, 'index')].each do |basename|
          filename = model_path("#{basename}.#{format}")
          if File.exist?(filename) && needs_loading?(path, filename)
            @@cache[path] = self.new(filename)
            break
          end
        end
      end
      @@cache[path]
    end

    def self.purge_cache
      @@cache = {}
    end

    def self.menu_items
      Nesta.deprecated('Page.menu_items', 'see Menu.top_level and Menu.for_path')
      Menu.top_level
    end

    def initialize(filename)
      @filename = filename
      @format = filename.split(".").last.to_sym
      if File.zero?(filename)
        @metadata = {}
        @markup = {}
      else
        @metadata, @markup = parse_file
      end
      @mtime = File.mtime(filename)
    end

    def index_page?
      @filename =~ /\/?index\.\w+$/
    end

    def abspath(options = {})
      options[:locale] ||= Nesta::Translations.current_locale
      page_path = @filename.sub(Nesta::Config.page_path, '')
      suffix = (options[:locale]!=:omit && options[:locale] != Nesta::App.first_locale(self)) ? "?locale=#{options[:locale]}" : ""
      if index_page?
        File.dirname(page_path)
      else
        File.join(File.dirname(page_path), File.basename(page_path, '.*'))
      end + suffix
    end

    def path(options = {})
      abspath(options).sub(/^\//, '')
    end

    def root?
      abspath(:locale => :omit) == "/"
    end

    def permalink
      File.basename(path)
    end

    def layout
      (metadata("layout") || "layout").to_sym
    end

    def template
      (metadata("template") || "page").to_sym
    end

    def to_html(scope = nil)
      convert_to_html(@format, scope, markup)
    end

    def last_modified
      @last_modified ||= File.stat(@filename).mtime
    end

    def description
      metadata("description")
    end

    def keywords
      metadata("keywords")
    end
    
    def metadata(key)
      @metadata[key]
    end

    def flagged_as?(flag)
      flags = metadata("flags")
      flags && flags.split(",").map { |name| name.strip }.include?(flag)
    end

    private
      def markup
        @markup
      end

    def parse_metadata(paragraph, existing = nil)
      retval = {}
      for line in paragraph.split("\n") do
        key, value = line.split(/\s*:\s*/, 2)
        retval[key.downcase] = value.chomp
      end
      existing ? existing.merge(retval || {}) : retval
    end

    def metadata?(text)
      text.split("\n").first =~ /^[\w ]+:/
    end

    def parse_file
      text = File.open(@filename).read
    rescue Errno::ENOENT
      raise Sinatra::NotFound
    else
      first_para, remaining = text.split(/\r?\n\r?\n/, 2)
      metadata = {}
      markup = {}
      if metadata?(first_para)
        language_key = first_para.match(/language_key\s*:\s*([^\s]+)\s*/) ? Regexp.last_match[1] : "language"
        if first_para !~ /#{language_key}\s*:\s*/i
          locale = first_para =~ /languages:\s*all\s*/i ? :all : Nesta::App.first_locale
          markup[locale] = remaining
          metadata[locale] = parse_metadata(first_para)
        else
          regexp = (/((?:[^\n]+\s*:[^\n]+\n)*)                # some fields before the "language:" field
                     (?:#{language_key}\s*:\s*([^\n]+)\n)  # the "language:" field
                     ((?:[^\n]+\s*:[^\n]+\n)*)                # some fields after the "language:" field
                    /xmi)
          match = text.match(regexp)
          while match
            locale = match.captures[1]
            metadata[:all] = parse_metadata(match.captures[0], metadata[:all])
            metadata[locale] = parse_metadata(match.captures[2])
            text = match.post_match
            match = text.match(regexp)
            markup[locale] = match ? match.pre_match : text
          end
        end
      else
        markup[Nesta::App.first_locale] = text
      end
      [Translations::LocalizedObject.new(metadata), Translations::LocalizedObject.new(markup)]
    end

      def convert_to_html(format, scope, text)
        case format
          when :mdown
            Maruku.new(text).to_html
          when :haml
            Haml::Engine.new(text).to_html(scope)
          when :textile
            RedCloth.new(text).to_html
          end
      end
  end


  class Page < FileModel
    def self.model_path(basename = nil)
      Nesta::Config.page_path(basename)
    end

    def self.find_by_path(path)
      page = load(path)
      page && page.hidden? ? nil : page
    end

    def self.find_all
      super.select { |p| ! p.hidden? }
    end

    def self.find_articles
      find_all.select do |page|
        page.date && page.date < DateTime.now
      end.sort { |x, y| y.date <=> x.date }
    end

    def ==(other)
      other.respond_to?(:path) && (self.path == other.path)
    end

    def draft?
      flagged_as?('draft')
    end

    def hidden?
      draft? && Nesta::App.production?
    end

    def heading
      regex = case @format
        when :mdown
          /^#\s*(.*?)(\s*#+|$)/
        when :haml
          /^\s*%h1\s+(.*)/
        when :textile
          /^\s*h1\.\s+(.*)/
        end
      markup =~ regex
      Regexp.last_match(1)
    end
  
    def title
      if metadata('title')
        metadata('title')
      elsif parent && (! parent.heading.nil?)
        "#{heading} - #{parent.heading}"
      elsif heading
        "#{heading} - #{Nesta::Config.title}"
      elsif abspath == '/'
        Nesta::Config.title
      end
    end

    def date(format = nil)
      @date ||= if metadata("date")
        if format == :xmlschema
          Time.parse(metadata("date")).xmlschema
        else
          DateTime.parse(metadata("date"))
        end
      end
    end

    def atom_id
      metadata('atom id')
    end

    def read_more
      metadata('read more') || 'Continue reading'
    end

    def summary
      if summary_text = metadata("summary")
        summary_text.gsub!('\n', "\n")
        case @format
        when :textile
          RedCloth.new(summary_text).to_html
        else
          Maruku.new(summary_text).to_html
        end
      end
    end

    def body(scope = nil)
      body_text = case @format
        when :mdown
          markup.sub(/^#[^#].*$\r?\n(\r?\n)?/, "")
        when :haml
          markup.sub(/^\s*%h1\s+.*$\r?\n(\r?\n)?/, "")
        when :textile
          markup.sub(/^\s*h1\.\s+.*$\r?\n(\r?\n)?/, "")
        end
      convert_to_html(@format, scope, body_text)
    end

    def categories
      paths = category_strings.map { |specifier| specifier.sub(/:-?\d+$/, '') }
      pages = valid_paths(paths).map { |p| Page.find_by_path(p) }
      pages.sort do |x, y|
        x.heading.downcase <=> y.heading.downcase
      end
    end

    def priority(category)
      category_string = category_strings.detect do |string|
        string =~ /^#{category}([,:\s]|$)/
      end
      category_string && category_string.split(':', 2)[-1].to_i 
    end

    def parent
      if abspath == '/'
        nil
      else
        parent_path = File.dirname(path)
        while parent_path != '.' do
          parent = Page.load(parent_path)
          return parent unless parent.nil?
          parent_path = File.dirname(parent_path)
        end
        Page.load('index')
      end
    end

    def pages
      in_category = Page.find_all.select do |page|
        page.date.nil? && page.categories.include?(self)
      end
      in_category.sort do |x, y|
        by_priority = y.priority(path) <=> x.priority(path)
        if by_priority == 0
          x.heading.downcase <=> y.heading.downcase
        else
          by_priority
        end
      end
    end

    def articles
      Page.find_articles.select { |article| article.categories.include?(self) }
    end

    private
      def category_strings
        strings = metadata('categories')
        strings.nil? ? [] : strings.split(',').map { |string| string.strip }
      end

      def valid_paths(paths)
        page_dir = Nesta::Config.page_path
        paths.select do |path|
          FORMATS.detect do |format|
            [path, File.join(path, 'index')].detect do |candidate|
              File.exist?(File.join(page_dir, "#{candidate}.#{format}"))
            end
          end
        end
      end
  end

  class Menu
    INDENT = " " * 2

    def self.full_menu
      menu = []
      menu_file = Nesta::Config.content_path('menu.txt')
      if File.exist?(menu_file)
        File.open(menu_file) { |file| append_menu_item(menu, file, 0) }
      end
      menu
    end

    def self.top_level
      full_menu.reject { |item| item.is_a?(Array) }
    end

    def self.for_path(path)
      path.sub!(Regexp.new('^/'), '')
      if path.empty?
        full_menu
      else
        find_menu_item_by_path(full_menu, path)
      end
    end

    private
      def self.append_menu_item(menu, file, depth)
        path = file.readline
      rescue EOFError
      else
        page = Page.load(path.strip)
        if page
          current_depth = path.scan(INDENT).size
          if current_depth > depth
            sub_menu_for_depth(menu, depth) << [page]
          else
            sub_menu_for_depth(menu, current_depth) << page
          end
          append_menu_item(menu, file, current_depth)
        end
      end

      def self.sub_menu_for_depth(menu, depth)
        sub_menu = menu
        depth.times { sub_menu = sub_menu[-1] }
        sub_menu
      end

      def self.find_menu_item_by_path(menu, path)
        item = menu.detect do |item|
          item.respond_to?(:path) && (item.path == path)
        end
        if item
          subsequent = menu[menu.index(item) + 1]
          item = [item]
          item << subsequent if subsequent.respond_to?(:each)
        else
          sub_menus = menu.select { |menu_item| menu_item.respond_to?(:each) }
          sub_menus.each do |sub_menu|
            item = find_menu_item_by_path(sub_menu, path)
            break if item
          end
        end
        item
      end

    end

    module Translations
      @@known_locales = []
      @@fallback_locale = nil

      def self.current_locale
        current_app = Nesta::App.current_app if defined?(Nesta::App)
        (current_app && current_app.current_locale) || @@fallback_locale
      end

      def self.known_locales=(locales)
        @@known_locales = locales
        @@fallback_locale ||= @@known_locales.first
      end

      def self.known_locales()
        @@known_locales
      end

      def self.fallback_locale=(locale)
        @@fallback_locale = locale
        unless @@known_locales.include? locale
          Kernel.warn("#{locale} is not known yet! Know only #{@@known_locales.join(", ")}")
        end
      end

      def self.fallback_locale()
        @@fallback_locale
      end
      # Stolen from https://github.com/jeremyevans/sequel/blob/master/lib/sequel/sql.rb
      # 
      if RUBY_VERSION < '1.9.0'
        # If on Ruby 1.8, create a <tt>Sequel::BasicObject</tt> class that is similar to the
        # the Ruby 1.9 +BasicObject+ class.  This is used in a few places where proxy
        # objects are needed that respond to any method call.
        class BasicObject
          # The instance methods to not remove from the class when removing
          # other methods.
          KEEP_METHODS = %w"__id__ __send__ __metaclass__ instance_eval == equal? initialize method_missing inspect"

          # Remove all but the most basic instance methods from the class.  A separate
          # method so that it can be called again if necessary if you load libraries
          # after Sequel that add instance methods to +Object+.
          def self.remove_methods!
            ((private_instance_methods + instance_methods) - KEEP_METHODS).each{|m| undef_method(m)}
          end
          remove_methods!
        end
      else
        # If on 1.9, create a <tt>Sequel::BasicObject</tt> class that is just like the
        # default +BasicObject+ class, except that missing constants are resolved in
        # +Object+.  This allows the virtual row support to work with classes
        # without prefixing them with ::, such as:
        #
        #   DB[:bonds].filter{maturity_date > Time.now}
        class BasicObject < ::BasicObject
          # Lookup missing constants in <tt>::Object</tt>
          def self.const_missing(name)
            ::Object.const_get(name)
          end

          # No-op method on ruby 1.9, which has a real +BasicObject+ class.
          def self.remove_methods!
          end
        end
      end
      
      class LocalizedObject < BasicObject
        def initialize(locale_hash)
          @stuff = locale_hash
          Translations.known_locales |= @stuff.keys
        end

        def method_missing(name, *args)
          # Kernel.puts "Called method_missing with #{name.to_s} and #{args.to_s}"
          @stuff[Translations.current_locale].send(name, *args)
        end

      end
    end
end

  
