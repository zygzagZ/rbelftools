# frozen_string_literal: true

require 'elftools/constants'
require 'elftools/sections/section'
require 'elftools/structs'
require 'elftools/enums'

module ELFTools
  module Sections
    # Class of note section.
    # Note section records notes
    class RelocationSection < Section
      attr_writer :relocations

      # Is this relocation a RELA or REL type.
      # @return [Boolean] If is RELA.
      def rela?
        header.sh_type == Constants::SHT_RELA
      end

      # Number of relocations in this section.
      # @return [Integer] The number.
      def num_relocations
        return 0 if header.sh_entsize.zero?

        header.sh_size / header.sh_entsize
      end

      # Acquire the +n+-th relocation, 0-based.
      #
      # relocations are lazy loaded.
      # @param [Integer] n The index.
      # @return [ELFTools::Relocation, nil]
      #   The target relocation.
      #   If +n+ is out of bound, +nil+ is returned.
      def relocation_at(n)
        @relocations ||= LazyArray.new(num_relocations, &method(:create_relocation))
        @relocations[n]&.tap { |rel| rel.index = n }
      end

      # Iterate all relocations.
      #
      # All relocations are lazy loading, the relocation
      # only be created whenever accessing it.
      # @yieldparam [ELFTools::Relocation] rel A relocation object.
      # @yieldreturn [void]
      # @return [Enumerator<ELFTools::Relocation>, Array<ELFTools::Relocation>]
      #   If block is not given, an enumerator will be returned.
      #   Otherwise, the whole relocations will be returned.
      def each_relocations(&block)
        return enum_for(:each_relocations) unless block_given?

        Array.new(num_relocations) do |i|
          relocation_at(i).tap(&block)
        end
      end

      # Simply use {#relocations} to get all relocations.
      # @return [Array<ELFTools::Relocation>]
      #   Whole relocations.
      def relocations
        each_relocations.to_a
      end

      # Regenereates section's data to be saved in a rebuilt file.
      # @return [String] Binary representation of section data
      def rebuild
        @data = ''
        each_relocations do |r|
          @data += r.header.to_binary_s
        end

        super
      end

      # Appends new relocation to the section.
      # Requires ELFFile rebuild to save changes.
      #
      # @param [Relocation32, Relocation64] type Relocation type, stored in header's r_info low bits.
      # @param [Integer] index Relocation symbol index, stored in header's r_info high bits.
      # @param [Integer] offset Relocation offset, stored in header's r_offset.
      # @param [Integer, nil] addend Relocation addend, required iff section is a RELA section.
      #   Stored in header's r_addend.
      # @return [Relocation]
      def append(type:, index:, offset:, addend: nil)
        raise ArgumentError, "#{addend.nil? ? '' : 'un'}expected addend" if addend.nil? == rela?

        klass = rela? ? Structs::ELF_Rela : Structs::ELF_Rel
        hdr = klass.new(endian: header.class.self_endian)
        hdr.elf_class = header.elf_class
        hdr.r_offset = offset
        hdr.r_addend = addend if addend

        res = Relocation.new(hdr, stream, self)
        res.type = type
        res.symbol_index = index

        @relocations ||= LazyArray.new(num_relocations, &method(:create_relocation))
        @relocations.push(res)

        self.data += hdr.to_binary_s
        header.sh_size += header.sh_entsize

        res
      end

      private

      def create_relocation(n)
        stream.pos = header.sh_offset + n * header.sh_entsize if stream
        klass = rela? ? Structs::ELF_Rela : Structs::ELF_Rel
        rel = klass.new(endian: header.class.self_endian, offset: stream&.pos)
        rel.elf_class = header.elf_class
        rel.read(stream) if stream
        Relocation.new(rel, stream, self)
      end
    end
  end

  # A relocation entry.
  #
  # Can be either a REL or RELA relocation.
  # XXX: move this to an independent file?
  class Relocation
    attr_reader :header # @return [ELFTools::Structs::ELF_Rel, ELFTools::Structs::ELF_Rela] Rel(a) header.
    attr_reader :stream # @return [#pos=, #read] Streaming object.
    attr_accessor :index # @return [ELFTools::Sections::RelocationSection] Section containing the relocation.

    class Relocation32 < Enum
      exclusive true
      enum_attr :none, 0
      enum_attr :"32", 1
      enum_attr :pc32, 2
      enum_attr :got32, 3
      enum_attr :plt32, 4
      enum_attr :copy, 5
      enum_attr :glob_dat, 6
      enum_attr :jmp_slot, 7
      enum_attr :relative, 8
      enum_attr :gotoff, 9
      enum_attr :gotpc, 10
      enum_attr :"32plt", 11
      enum_attr :"16", 20
      enum_attr :pc16, 21
      enum_attr :"8", 22
      enum_attr :pc8, 23
      enum_attr :size32, 38
    end

    class Relocation64 < Enum
      exclusive true
      enum_attr :none, 0
      enum_attr :"64", 1
      enum_attr :pc32, 2
      enum_attr :got32, 3
      enum_attr :plt32, 4
      enum_attr :copy, 5
      enum_attr :glob_dat, 6
      enum_attr :jump_slot, 7
      enum_attr :relative, 8
      enum_attr :gotpcrel, 9
      enum_attr :"32", 10
      enum_attr :"32s", 11
      enum_attr :"16", 12
      enum_attr :pc16, 13
      enum_attr :"8", 14
      enum_attr :pc8, 15
      enum_attr :pc64, 24
      enum_attr :gotoff64, 25
      enum_attr :gotpc32, 26
      enum_attr :size32, 32
      enum_attr :size64, 33
    end

    # Hash containing x86 relocation types class depending on elf_class
    RELOCATION_ARCH = {
      32 => Relocation32,
      64 => Relocation64
    }.freeze

    # Instantiate a {Relocation} object.
    def initialize(header, stream, section = nil)
      @header = header
      @stream = stream
      # Proc wrapper used for {ELFFile#loaded_headers} to work
      @section = section && -> { section }
    end

    # Returns section containing the relocation.
    # @return [ELFTools::Sections::RelocationSection] section
    def section
      @section.call
    end

    # +r_info+ contains sym and type, use two methods
    # to access them easier.
    # @return [Integer] sym infor.
    def r_info_sym
      header.r_info >> mask_bit
    end
    alias symbol_index r_info_sym

    # +r_info+ contains sym and type, use two methods
    # to access them easier.
    # @return [Integer] type infor.
    def r_info_type
      header.r_info & ((1 << mask_bit) - 1)
    end
    alias type r_info_type

    # Convenience method returning relocation type wrapped in an Relocation Enum type.
    # @param [Integer] bits Use {bits} x86 arch instead of elf_class to parse type enum.
    # @return [Relocation32, Relocation64] relocation type enum
    def type_enum(bits = header.elf_class)
      RELOCATION_ARCH[bits].new(type)
    end

    # Update relocation type.
    # @param [String, Relocation64, RElocation32, Integer] type Relocation type
    def type=(type)
      type = RELOCATION_ARCH[header.elf_class].new(type) if type.is_a? String
      mask = (1 << mask_bit) - 1
      header.r_info = (header.r_info & (~mask)) | (type.to_i & mask)
    end

    # Update relocation symbol index.
    # @param [Integer] ind symbol index.
    def symbol_index=(ind)
      mask = (1 << mask_bit) - 1
      header.r_info = (ind << mask_bit) | (header.r_info & mask)
    end

    def mask_bit(bits = header.elf_class)
      bits == 32 ? 8 : 32
    end

    # Returns relocation symbol name read from ".strtab" section at offset from ".symtab"
    def symbol_name
      section.elf.symtab.symbols[symbol_index].name
    end
  end
end
