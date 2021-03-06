require 'forwardable'
require 'lotus/utils/kernel'

module Lotus
  module Model
    module Adapters
      module Dynamodb
        # Query DynamoDB table with a powerful API.
        #
        # All the methods are chainable, it allows advanced composition of
        # options.
        #
        # This works as a lazy filtering mechanism: the records are fetched from
        # the DynamoDB only when needed.
        #
        # @example
        #
        #   query.where(language: 'ruby')
        #        .and(framework: 'lotus')
        #        .all
        #
        #   # the records are fetched only when we invoke #all
        #
        # It implements Ruby's `Enumerable` and borrows some methods from `Array`.
        # Expect a query to act like them.
        #
        # @since 0.1.0
        class Query
          include Enumerable
          extend  Forwardable

          def_delegators :all, :each, :to_s, :empty?

          # @attr_reader operation [Symbol] operation to perform
          #
          # @since 0.1.0
          # @api private
          attr_reader :operation

          # @attr_reader options [Hash] an accumulator for the query options
          #
          # @since 0.1.0
          # @api private
          attr_reader :options

          # Initialize a query
          #
          # @param dataset [Lotus::Model::Adapters::Dynamodb::Collection]
          # @param collection [Lotus::Model::Mapping::Collection]
          # @param blk [Proc] an optional block that gets yielded in the
          #   context of the current query
          #
          # @since 0.1.0
          # @api private
          def initialize(dataset, collection, &blk)
            @dataset    = dataset
            @collection = collection

            @operation  = :scan
            @options    = {}

            instance_eval(&blk) if block_given?
          end

          # Resolves the query by fetching records from the database and
          # translating them into entities.
          #
          # @return [Array] a collection of entities
          #
          # @since 0.1.0
          def all
            @collection.deserialize(run.entries)
          end

          # Set operation to be query instead of scan.
          #
          # @return self
          #
          # @since 0.1.0
          def query
            @operation = :query
            self
          end

          # Adds a condition that behaves like SQL `WHERE`.
          #
          # It accepts a `Hash` with only one pair.
          # The key must be the name of the column expressed as a `Symbol`.
          # The value is the one used by the internal filtering logic.
          #
          # @param condition [Hash]
          #
          # @return self
          #
          # @since 0.1.0
          #
          # @example Fixed value
          #
          #   query.where(language: 'ruby')
          #
          # @example Array
          #
          #   query.where(id: [1, 3])
          #
          # @example Range
          #
          #   query.where(year: 1900..1982)
          #
          # @example Multiple conditions
          #
          #   query.where(language: 'ruby')
          #        .where(framework: 'lotus')
          def where(condition)
            key = key_for_condition(condition)
            serialized = serialize_condition(condition)

            if serialized
              @options[key] ||= {}
              @options[key].merge!(serialized)
            end

            self
          end

          # Sets DynamoDB ConditionalOperator to `OR`. This works query-wide
          # so this method has no arguments.
          #
          # @return self
          #
          # @since 0.1.0
          def or
            @options[:conditional_operator] = "OR"
            self
          end

          # Logical negation of a #where condition.
          #
          # It accepts a `Hash` with only one pair.
          # The key must be the name of the column expressed as a `Symbol`.
          # The value is the one used by the internal filtering logic.
          #
          # @param condition [Hash]
          #
          # @since 0.1.0
          #
          # @return self
          #
          # @example Fixed value
          #
          #   query.exclude(language: 'java')
          #
          # @example Multiple conditions
          #
          #   query.exclude(language: 'java')
          #        .exclude(company: 'enterprise')
          def exclude(condition)
            key = key_for_condition(condition)
            serialized = serialize_condition(condition, true)

            if serialized
              @options[key] ||= {}
              @options[key].merge!(serialized)
            end

            self
          end

          alias_method :not, :exclude

          # Select only the specified columns.
          #
          # By default a query selects all the mapped columns.
          #
          # @param columns [Array<Symbol>]
          #
          # @return self
          #
          # @since 0.1.0
          #
          # @example Single column
          #
          #   query.select(:name)
          #
          # @example Multiple columns
          #
          #   query.select(:name, :year)
          def select(*columns)
            @options[:select] = "SPECIFIC_ATTRIBUTES"
            @options[:attributes_to_get] = columns.map(&:to_s)
            self
          end

          # Specify the ascending order of the records, sorted by the range key.
          #
          # @return self
          #
          # @since 0.1.0
          #
          # @see Lotus::Model::Adapters::Dynamodb::Query#desc
          def order(*columns)
            warn "DynamoDB does not support arbitrary order" if columns.any?

            query
            @options[:scan_index_forward] = true
            self
          end

          alias_method :asc, :order

          # Specify the descending order of the records, sorted by the range key.
          #
          # @return self
          #
          # @since 0.1.0
          #
          # @see Lotus::Model::Adapters::Dynamodb::Query#asc
          def desc(*columns)
            warn "DynamoDB does not support arbitrary order" if columns.any?

            query
            @options[:scan_index_forward] = false
            self
          end

          # Limit the number of records to return.
          #
          # @param number [Fixnum]
          #
          # @return self
          #
          # @since 0.1.0
          #
          # @example
          #
          #   query.limit(1)
          def limit(number)
            @options[:limit] = number
            self
          end

          # This method is not implemented. DynamoDB does not provide offset.
          #
          # @param number [Fixnum]
          #
          # @raise [NotImplementedError]
          #
          # @since 0.1.0
          def offset(number)
            raise NotImplementedError
          end

          # This method is not implemented. DynamoDB does not provide sum.
          #
          # @param column [Symbol] the column name
          #
          # @raise [NotImplementedError]
          #
          # @since 0.1.0
          def sum(column)
            raise NotImplementedError
          end

          # This method is not implemented. DynamoDB does not provide average.
          #
          # @param column [Symbol] the column name
          #
          # @raise [NotImplementedError]
          #
          # @since 0.1.0
          def average(column)
            raise NotImplementedError
          end

          alias_method :avg, :average

          # This method is not implemented. DynamoDB does not provide max.
          #
          # @param column [Symbol] the column name
          #
          # @raise [NotImplementedError]
          #
          # @since 0.1.0
          def max(column)
            raise NotImplementedError
          end

          # This method is not implemented. DynamoDB does not provide min.
          #
          # @param column [Symbol] the column name
          #
          # @raise [NotImplementedError]
          #
          # @since 0.1.0
          def min(column)
            raise NotImplementedError
          end

          # This method is not implemented. DynamoDB does not provide interval.
          #
          # @param column [Symbol] the column name
          #
          # @raise [NotImplementedError]
          #
          # @since 0.1.0
          def interval(column)
            raise NotImplementedError
          end

          # This method is not implemented. DynamoDB does not provide range.
          #
          # @param column [Symbol] the column name
          #
          # @raise [NotImplementedError]
          #
          # @since 0.1.0
          def range(column)
            raise NotImplementedError
          end

          # Checks if at least one record exists for the current conditions.
          #
          # @return [TrueClass,FalseClass]
          #
          # @since 0.1.0
          #
          # @example
          #
          #    query.where(author_id: 23).exists? # => true
          def exist?
            !count.zero?
          end

          # Returns a count of the records for the current conditions.
          #
          # @return [Fixnum]
          #
          # @since 0.1.0
          #
          # @example
          #
          #    query.where(author_id: 23).count # => 5
          def count
            @options[:select] = "COUNT"
            @options.delete(:attributes_to_get)

            run.count
          end

          # This method is not implemented.
          #
          # @raise [NotImplementedError]
          #
          # @since 0.1.0
          def negate!
            raise NotImplementedError
          end

          # Tells DynamoDB to use consistent reads.
          #
          # @return self
          #
          # @since 0.1.0
          def consistent
            query
            @options[:consistent_read] = true
            self
          end

          # Tells DynamoDB which index to use.
          #
          # @return self
          #
          # @since 0.1.0
          def index(name)
            query
            @options[:index_name] = name.to_s
            self
          end

          # TODO: More DynamoDB-specific methods

          private
          # Return proper options key for a given condition.
          #
          # @param condition [Hash] the condition
          #
          # @return [Symbol] the key
          #
          # @api private
          # @since 0.1.0
          def key_for_condition(condition)
            if @dataset.key?(condition.keys.first, @options[:index_name])
              query
              :key_conditions
            elsif operation == :scan
              :scan_filter
            else
              :query_filter
            end
          end

          # Serialize given condition for DynamoDB API.
          #
          # @param condition [Hash] the condition
          # @param negate [Boolean] true when negative condition
          #
          # @return [Hash] the serialized condition
          #
          # @api private
          # @since 0.1.0
          def serialize_condition(condition, negate = false)
            column, value = condition.keys.first, condition.values.first

            operator ||= case
            when value.is_a?(Array)
              negate ? nil : "IN"
            when value.is_a?(Range)
              negate ? nil : "BETWEEN"
            else
              negate ? "NE" : "EQ"
            end

            # Operator is not supported
            raise NotImplementedError unless operator

            values ||= case
            when value.is_a?(Range)
              [value.first, value.last]
            else
              [value].flatten
            end

            {
              column.to_s => {
                attribute_value_list: values.map do |v|
                  @dataset.format_attribute_value(v)
                end,
                comparison_operator: operator,
              },
            }
          end

          # Apply all the options and return a filtered collection.
          #
          # @return [Array]
          #
          # @api private
          # @since 0.1.0
          def run
            @dataset.public_send(operation, @options)
          end
        end
      end
    end
  end
end
