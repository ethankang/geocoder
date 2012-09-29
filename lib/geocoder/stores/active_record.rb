require 'geocoder/sql'
require 'geocoder/stores/base'

##
# Add geocoding functionality to any ActiveRecord object.
#
module Geocoder::Store
  module ActiveRecord
    include Base

    ##
    # Implementation of 'included' hook method.
    #
    def self.included(base)
      base.extend ClassMethods
      base.class_eval do

        # scope: geocoded objects
        scope :geocoded, lambda {
          {:conditions => "#{geocoder_options[:latitude]} IS NOT NULL " +
            "AND #{geocoder_options[:longitude]} IS NOT NULL"}}

        # scope: not-geocoded objects
        scope :not_geocoded, lambda {
          {:conditions => "#{geocoder_options[:latitude]} IS NULL " +
            "OR #{geocoder_options[:longitude]} IS NULL"}}

        ##
        # Find all objects within a radius of the given location.
        # Location may be either a string to geocode or an array of
        # coordinates (<tt>[lat,lon]</tt>). Also takes an options hash
        # (see Geocoder::Orm::ActiveRecord::ClassMethods.near_scope_options
        # for details).
        #
        scope :near, lambda{ |location, *args|
          latitude, longitude = Geocoder::Calculations.extract_coordinates(location)
          if Geocoder::Calculations.coordinates_present?(latitude, longitude)
            near_scope_options(latitude, longitude, *args)
          else
            # If no lat/lon given we don't want any results, but we still
            # need distance and bearing columns so you can add, for example:
            # .order("distance")
            select(select_clause(nil, "NULL", "NULL")).where(false_condition)
          end
        }

        ##
        # Find all objects within the area of a given bounding box.
        # Bounds must be an array of locations specifying the southwest
        # corner followed by the northeast corner of the box
        # (<tt>[[sw_lat, sw_lon], [ne_lat, ne_lon]]</tt>).
        #
        scope :within_bounding_box, lambda{ |bounds|
          sw_lat, sw_lng, ne_lat, ne_lng = bounds.flatten if bounds
          if sw_lat && sw_lng && ne_lat && ne_lng
            {:conditions => Geocoder::Sql.within_bounding_box(
              sw_lat, sw_lng, ne_lat, ne_lng,
              full_column_name(geocoder_options[:latitude]),
              full_column_name(geocoder_options[:longitude])
            )}
          else
            select(select_clause(nil, "NULL", "NULL")).where(false_condition)
          end
        }
      end
    end

    ##
    # Methods which will be class methods of the including class.
    #
    module ClassMethods

      def distance_from_sql(location, *args)
        latitude, longitude = Geocoder::Calculations.extract_coordinates(location)
        if Geocoder::Calculations.coordinates_present?(latitude, longitude)
          distance_from_sql_options(latitude, longitude, *args)
        end
      end

      private # ----------------------------------------------------------------

      ##
      # Get options hash suitable for passing to ActiveRecord.find to get
      # records within a radius (in kilometers) of the given point.
      # Options hash may include:
      #
      # * +:units+   - <tt>:mi</tt> or <tt>:km</tt>; to be used.
      #   for interpreting radius as well as the +distance+ attribute which
      #   is added to each found nearby object.
      #   See Geocoder::Configuration to know how configure default units.
      # * +:bearing+ - <tt>:linear</tt> or <tt>:spherical</tt>.
      #   the method to be used for calculating the bearing (direction)
      #   between the given point and each found nearby point;
      #   set to false for no bearing calculation.
      #   See Geocoder::Configuration to know how configure default method.
      # * +:select+  - string with the SELECT SQL fragment (e.g. “id, name”)
      # * +:order+   - column(s) for ORDER BY SQL clause; default is distance
      # * +:exclude+ - an object to exclude (used by the +nearbys+ method)
      #
      def near_scope_options(latitude, longitude, radius = 20, options = {})
        method_prefix = using_sqlite? ? "approx" : "full"
        send(
          method_prefix + "_near_scope_options",
          latitude, longitude, radius, options
        )
      end

      def distance_from_sql_options(latitude, longitude, options = {})
        method_prefix = using_sqlite? ? "approx" : "full"
        Geocoder::Sql.send(
          method_prefix + "_distance",
          latitude, longitude,
          full_column_name(geocoder_options[:latitude]),
          full_column_name(geocoder_options[:longitude]),
          options
        )
      end

      ##
      # Scope options hash for use with a database that supports POWER(),
      # SQRT(), PI(), and trigonometric functions SIN(), COS(), ASIN(),
      # ATAN2(), DEGREES(), and RADIANS().
      #
      def full_near_scope_options(latitude, longitude, radius, options)
        if !options.include?(:bearing)
          options[:bearing] = Geocoder::Configuration.distances
        end
        if options[:bearing]
          bearing = Geocoder::Sql.full_bearing(
            latitude, longitude,
            full_column_name(geocoder_options[:latitude]),
            full_column_name(geocoder_options[:longitude]),
            options
          )
        end
        options[:units] ||= (geocoder_options[:units] || Geocoder::Configuration.units)
        distance = distance_from_sql_options(latitude, longitude, options)
        conditions = ["#{distance} <= ?", radius]
        default_near_scope_options(latitude, longitude, radius, options).merge(
          :select => select_clause(options[:select], distance, bearing),
          :conditions => add_exclude_condition(conditions, options[:exclude])
        )
      end

      ##
      # Scope options hash for use with a database without trigonometric
      # functions, like SQLite. Approach is to find objects within a square
      # rather than a circle, so results are very approximate (will include
      # objects outside the given radius).
      #
      # Distance and bearing calculations are *extremely inaccurate*. They
      # only exist for interface consistency--not intended for production!
      #
      def approx_near_scope_options(latitude, longitude, radius, options)
        if !options.include?(:bearing)
          options[:bearing] = Geocoder::Configuration.distances
        end
        if options[:bearing]
          bearing = Geocoder::Sql.approx_bearing(
            latitude, longitude,
            full_column_name(geocoder_options[:latitude]),
            full_column_name(geocoder_options[:longitude])
          )
        else
          bearing = false
        end

        options[:units] ||= (geocoder_options[:units] || Geocoder::Configuration.units)
        distance = distance_from_sql_options(latitude, longitude, options)

        b = Geocoder::Calculations.bounding_box([latitude, longitude], radius, options)
        args = b + [
          full_column_name(geocoder_options[:latitude]),
          full_column_name(geocoder_options[:longitude])
        ]
        conditions = Geocoder::Sql.within_bounding_box(*args)
        default_near_scope_options(latitude, longitude, radius, options).merge(
          :select => select_clause(options[:select], distance, bearing),
          :conditions => add_exclude_condition(conditions, options[:exclude])
        )
      end

      ##
      # Generate the SELECT clause.
      #
      def select_clause(columns, distance, bearing)
        if columns == :geo_only
          clause = ""
        else
          clause = (columns || full_column_name("*")) + ", "
        end
        clause + "#{distance} AS distance" +
          (bearing ? ", #{bearing} AS bearing" : "")
      end

      ##
      # Options used for any near-like scope.
      #
      def default_near_scope_options(latitude, longitude, radius, options)
        {
          :order  => options[:order] || "distance",
          :limit  => options[:limit],
          :offset => options[:offset]
        }
      end

      ##
      # Adds a condition to exclude a given object by ID.
      # Expects conditions as an array or string. Returns array.
      #
      def add_exclude_condition(conditions, exclude)
        conditions = [conditions] if conditions.is_a?(String)
        if exclude
          conditions[0] << " AND #{full_column_name(primary_key)} != ?"
          conditions << exclude.id
        end
        conditions
      end

      def using_sqlite?
        connection.adapter_name.match /sqlite/i
      end

      ##
      # Value which can be passed to where() to produce no results.
      #
      def false_condition
        using_sqlite? ? 0 : "false"
      end

      ##
      # Prepend table name if column name doesn't already contain one.
      #
      def full_column_name(column)
        column = column.to_s
        column.include?(".") ? column : [table_name, column].join(".")
      end
    end

    ##
    # Look up coordinates and assign to +latitude+ and +longitude+ attributes
    # (or other as specified in +geocoded_by+). Returns coordinates (array).
    #
    def geocode
      do_lookup(false) do |o,rs|
        if r = rs.first
          unless r.latitude.nil? or r.longitude.nil?
            o.__send__  "#{self.class.geocoder_options[:latitude]}=",  r.latitude
            o.__send__  "#{self.class.geocoder_options[:longitude]}=", r.longitude
          end
          r.coordinates
        end
      end
    end

    alias_method :fetch_coordinates, :geocode

    ##
    # Look up address and assign to +address+ attribute (or other as specified
    # in +reverse_geocoded_by+). Returns address (string).
    #
    def reverse_geocode
      do_lookup(true) do |o,rs|
        if r = rs.first
          unless r.address.nil?
            o.__send__ "#{self.class.geocoder_options[:fetched_address]}=", r.address
          end
          r.address
        end
      end
    end

    alias_method :fetch_address, :reverse_geocode
  end
end

