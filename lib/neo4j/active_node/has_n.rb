module Neo4j::ActiveNode
  module HasN
    extend ActiveSupport::Concern

    class NonPersistedNodeError < StandardError; end

    # Clears out the association cache.
    def clear_association_cache #:nodoc:
      association_cache.clear if _persisted_obj
    end

    # Returns the current association cache. It is in the format
    # { :association_name => { :hash_of_cypher_string => [collection] }}
    def association_cache
      @association_cache ||= {}
    end

    # Returns the specified association instance if it responds to :loaded?, nil otherwise.
    # @param [String] cypher_string the cypher, with params, used for lookup
    # @param [Enumerable] association_obj the HasN::Association object used to perform this query
    def association_instance_get(cypher_string, association_obj)
      return if association_cache.nil? || association_cache.empty?
      lookup_obj = cypher_hash(cypher_string)
      reflection = association_reflection(association_obj)
      return if reflection.nil?
      association_cache[reflection.name] ? association_cache[reflection.name][lookup_obj] : nil
    end

    # @return [Hash] A hash of all queries inassociation_cache created from the association owning this reflection
    def association_instance_get_by_reflection(reflection_name)
      association_cache[reflection_name]
    end

    # Caches an association result. Unlike ActiveRecord, which stores results in @association_cache using { :association_name => [collection_result] },
    # ActiveNode stores it using { :association_name => { :hash_string_of_cypher => [collection_result] }}.
    # This is necessary because an association name by itself does not take into account :where, :limit, :order, etc,... so it's prone to error.
    # @param [Neo4j::ActiveNode::Query::QueryProxy] query_proxy The QueryProxy object that resulted in this result
    # @param [Enumerable] collection_result The result of the query after calling :each
    # @param [Neo4j::ActiveNode::HasN::Association] association_obj The association traversed to create the result
    def association_instance_set(cypher_string, collection_result, association_obj)
      return collection_result if Neo4j::Transaction.current
      cache_key = cypher_hash(cypher_string)
      reflection = association_reflection(association_obj)
      return if reflection.nil?
      if @association_cache[reflection.name]
        @association_cache[reflection.name][cache_key] = collection_result
      else
        @association_cache[reflection.name] = {cache_key => collection_result}
      end
      collection_result
    end

    def association_instance_fetch(cypher_string, association_obj, &block)
      association_instance_get(cypher_string, association_obj) || association_instance_set(cypher_string, block.call, association_obj)
    end

    def association_reflection(association_obj)
      self.class.reflect_on_association(association_obj.name)
    end

    # Uses the cypher generated by a QueryProxy object, complete with params, to generate a basic non-cryptographic hash
    # for use in @association_cache.
    # @param [String] the cypher used in the query
    # @return [String] A basic hash of the query
    def cypher_hash(cypher_string)
      cypher_string.hash.abs
    end

    def association_query_proxy(name, options = {})
      self.class.association_query_proxy(name, {start_object: self}.merge(options))
    end

    private

    def validate_persisted_for_association!
      fail(Neo4j::ActiveNode::HasN::NonPersistedNodeError, 'Unable to create relationship with non-persisted nodes') unless self._persisted_obj
    end

    module ClassMethods
      # :nocov:
      # rubocop:disable Style/PredicateName
      def has_association?(name)
        ActiveSupport::Deprecation.warn 'has_association? is deprecated and may be removed from future releases, use association? instead.', caller

        association?(name)
      end
      # rubocop:enable Style/PredicateName
      # :nocov:

      def association?(name)
        !!associations[name.to_sym]
      end

      def associations
        @associations || {}
      end

      # make sure the inherited classes inherit the <tt>_decl_rels</tt> hash
      def inherited(klass)
        klass.instance_variable_set(:@associations, associations.clone)
        super
      end

      # For defining an "has many" association on a model.  This defines a set of methods on
      # your model instances.  For instance, if you define the association on a Person model:
      #
      # has_many :out, :vehicles, type: :has_vehicle
      #
      # This would define the following methods:
      # 
      # **#vehicles**
      #   Returns a QueryProxy object.  This is an Enumerable object and thus can be iterated
      #   over.  It also has the ability to accept class-level methods from the Vehicle model
      #   (including calls to association methods)
      #
      # **#vehicles=**
      #   Takes an array of Vehicle objects and replaces all current ``:HAS_VEHICLE`` relationships
      #   with new relationships refering to the specified objects
      #
      # **.vehicles**
      #   Returns a QueryProxy object.  This would represent all ``Vehicle`` objects associated with
      #   either all ``Person`` nodes (if ``Person.vehicles`` is called), or all ``Vehicle`` objects
      #   associated with the ``Person`` nodes thus far represented in the QueryProxy chain.
      #   For example:
      #     ``company.people.where(age: 40).vehicles``
      #
      # Arguments:
      #   **direction:**
      #     **Available values:** ``:in``, ``:out``, or ``:both``.
      #
      #     Refers to the relative to the model on which the association is being defined.
      # 
      #     Example:
      #       ``Person.has_many :out, :posts, type: :wrote``
      #
      #         means that a `WROTE` relationship goes from a `Person` node to a `Post` node
      #
      #   **name:**
      #     The name of the association.  The affects the methods which are created (see above).
      #     The name is also used to form default assumptions about the model which is being referred to
      #
      #     Example:
      #       ``Person.has_many :out, :posts``
      #
      #       will assume a `model_class` option of ``'Post'`` unless otherwise specified
      #
      #   **options:** A ``Hash`` of options.  Allowed keys are:
      #     *type*: The Neo4j relationship type
      #
      #     *model_class*: The model class to which the association is referring.  Can be either a
      #       model `Class` object or a string (or an Array of same).
      #       **A string is recommended** to avoid load-time issues
      #
      #     *dependent*: Enables deletion cascading.
      #       **Available values:** ``:delete``, ``:delete_orphans``, ``:destroy``, ``:destroy_orphans``
      #       (note that the ``:destroy_orphans`` option is known to be "very metal".  Caution advised)
      #
      def has_many(direction, name, options = {}) # rubocop:disable Style/PredicateName
        name = name.to_sym
        build_association(:has_many, direction, name, options)

        define_has_many_methods(name)
      end

      # For defining an "has one" association on a model.  This defines a set of methods on
      # your model instances.  For instance, if you define the association on a Person model:
      #
      # has_one :out, :vehicle, type: :has_vehicle
      #
      # This would define the methods: ``#vehicle``, ``#vehicle=``, and ``.vehicle``.
      #
      # See :ref:`#has_many <Neo4j/ActiveNode/HasN/ClassMethods#has_many>` for anything
      # not specified here
      # 
      def has_one(direction, name, options = {}) # rubocop:disable Style/PredicateName
        name = name.to_sym
        build_association(:has_one, direction, name, options)

        define_has_one_methods(name)
      end

      private

      def define_has_many_methods(name)
        define_method(name) do |node = nil, rel = nil, options = {}|
          return [].freeze unless self._persisted_obj

          association_query_proxy(name, {node: node, rel: rel, caller: self}.merge(options))
        end

        define_method("#{name}=") do |other_nodes|
          clear_association_cache
          association_query_proxy(name).replace_with(other_nodes)
        end

        define_class_method(name) do |node = nil, rel = nil, proxy_obj = nil, options = {}|
          association_query_proxy(name, {node: node, rel: rel, proxy_obj: proxy_obj}.merge(options))
        end
      end

      def define_has_one_methods(name)
        define_method(name) do |node = nil, rel = nil|
          return nil unless self._persisted_obj

          result = association_query_proxy(name, node: node, rel: rel)
          association_instance_fetch(result.to_cypher_with_params,
                                     self.class.reflect_on_association(__method__)) { result.first }
        end

        define_method("#{name}=") do |other_node|
          validate_persisted_for_association!
          clear_association_cache
          association_query_proxy(name).replace_with(other_node)
        end

        define_class_method(name) do |node = nil, rel = nil, query_proxy = nil, options = {}|
          association_query_proxy(name, {query_proxy: query_proxy, node: node, rel: rel}.merge(options))
        end
      end

      def define_class_method(*args, &block)
        klass = class << self; self; end
        klass.instance_eval do
          define_method(*args, &block)
        end
      end

      def association_query_proxy(name, options = {})
        query_proxy = options[:proxy_obj] || default_association_proxy_obj(name)

        Neo4j::ActiveNode::Query::QueryProxy.new(association_target_class(name),
                                                 associations[name],
                                                 {session: neo4j_session,
                                                  query_proxy: query_proxy,
                                                  context: "#{query_proxy.context || self.name}##{name}",
                                                  optional: query_proxy.optional?,
                                                  caller: query_proxy.caller}.merge(options)).tap do |query_proxy_result|
                                                    target_classes = association_target_classes(name)
                                                    return query_proxy_result.as_models(target_classes) if target_classes
                                                  end
      end

      def association_target_class(name)
        target_classes_or_nil = associations[name].target_classes_or_nil

        return if !target_classes_or_nil.is_a?(Array) || target_classes_or_nil.size != 1

        target_classes_or_nil[0]
      end

      def association_target_classes(name)
        target_classes_or_nil = associations[name].target_classes_or_nil

        return if !target_classes_or_nil.is_a?(Array) || target_classes_or_nil.size <= 1

        target_classes_or_nil
      end

      def default_association_proxy_obj(name)
        Neo4j::ActiveNode::Query::QueryProxy.new("::#{self.class.name}".constantize,
                                                 nil,
                                                 session: neo4j_session,
                                                 query_proxy: nil,
                                                 context: "#{self.name}##{name}")
      end

      def build_association(macro, direction, name, options)
        Neo4j::ActiveNode::HasN::Association.new(macro, direction, name, options).tap do |association|
          @associations ||= {}
          @associations[name] = association
          create_reflection(macro, name, association, self)
        end
      end
    end
  end
end
