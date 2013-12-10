module Pelias

  class Base

    include Sidekiq::Worker

    INDEX = 'pelias'

    def initialize(params)
      set_instance_variables(params)
    end

    def save
      attributes = to_hash
      id = attributes.delete('id')
      suggestions = generate_suggestions
      attributes['suggest'] = suggestions if suggestions
      ES_CLIENT.index(index: INDEX, type: type, id: id, body: attributes,
        timeout: "#{ES_TIMEOUT}s")
    end

    def update(params)
      set_instance_variables(params)
    end

    def self.build(params)
      obj = self.new(params)
      obj.set_encompassing_shapes if street_level?
      obj.set_admin_names unless street_level?
      obj
    end

    def self.create(params)
      if params.is_a? Array
        bulk = params.map do |param|
          obj = self.build(param)
          hash = obj.to_hash
          suggestions = obj.generate_suggestions
          hash['suggest'] = suggestions if suggestions
          { index: { _id: hash.delete('id'), data: hash } }
        end
        ES_CLIENT.bulk(index: INDEX, type: type, body: bulk)
      else
        obj = self.build(params)
        obj.save
        obj
      end
    end

    def self.find(id)
      result = ES_CLIENT.get(index: INDEX, type: type, id: id, ignore: 404)
      return unless result
      obj = self.new(:id=>id)
      obj.update(result['_source'])
      obj
    end

    def self.type
      self.name.split('::').last.gsub(/(.)([A-Z])/,'\1_\2').downcase
    end

    def self.street_level?
      false
    end

    def self.reindex_bulk(results)
      bulk = results['hits']['hits'].map do |result|
        obj = self.new(result['_source'])
        suggest = obj.generate_suggestions
        # just updating suggestions for now
        {
          update: {
            _id: result['_id'],
            data: { doc: { suggest: suggest } }
          }
        }
      end
      Pelias::ES_CLIENT.bulk(index: INDEX, type: type, body: bulk)
    end

    def self.reindex_all(size=50)
      i=0
      results = Pelias::ES_CLIENT.search(index: 'pelias',
        type: self.type, scroll: '10m', size: size,
        body: { query: { match_all: {} }, sort: '_id' })
      puts i
      i+=50
      self.delay.reindex_bulk(results)
      begin
        results = Pelias::ES_CLIENT.scroll(scroll: '10m',
          scroll_id: results['_scroll_id'])
        self.delay.reindex_bulk(results)
        puts i
        i+=50
      end while results['hits']['hits'].count > 0
    end

    def reindex(update_geometries=false, set_shapes=false)
      if set_shapes
        self.set_encompassing_shapes
      end
      to_reindex = self.to_hash
      to_reindex.delete('id')
      unless update_geometries
        to_reindex.delete('center_point')
        to_reindex.delete('center_shape')
        to_reindex.delete('boundaries')
      end
      to_reindex['suggest'] = generate_suggestions
      Pelias::ES_CLIENT.update(index: INDEX, type: type, id: id,
        retry_on_conflict: 5, body: { doc: to_reindex })
    end

    def admin1_abbr
      admin1_code if country_code=='US'
    end

    def lat
      center_point[1]
    end

    def lon
      center_point[0]
    end

    def set_encompassing_shapes
      params = {}
      if type!='local_admin' && local_admin=encompassing_shape('local_admin')
        source = local_admin['_source']
        params[:local_admin_id] = local_admin['_id']
        params[:local_admin_name] = source['name']
        params[:local_admin_alternate_names] = source['alternate_names']
        params[:local_admin_population] = source['population']
        params[:country_code] = source['country_code']
        params[:country_name] = source['country_name']
        params[:admin1_code] = source['admin1_code']
        params[:admin1_name] = source['admin1_name']
        params[:admin2_code] = source['admin2_code']
        params[:admin2_name] = source['admin2_name']
      end
      if type!='locality' && locality=encompassing_shape('locality')
        source = locality['_source']
        params[:locality_id] = locality['_id']
        params[:locality_name] = source['name']
        params[:locality_alternate_names] = source['alternate_names']
        params[:locality_population] = source['population']
        params[:country_code] = source['country_code']
        params[:country_name] = source['country_name']
        params[:admin1_code] = source['admin1_code']
        params[:admin1_name] = source['admin1_name']
        params[:admin2_code] = source['admin2_code']
        params[:admin2_name] = source['admin2_name']
      end
      if type!='neighborhood' && neighborhood=encompassing_shape('neighborhood')
        source = neighborhood['_source']
        params[:neighborhood_id] = neighborhood['_id']
        params[:neighborhood_name] = source['name']
        params[:neighborhood_alternate_names] = source['alternate_names']
        params[:neighborhood_population] = source['population']
        params[:country_code] = source['country_code']
        params[:country_name] = source['country_name']
        params[:admin1_code] = source['admin1_code']
        params[:admin1_name] = source['admin1_name']
        params[:admin2_code] = source['admin2_code']
        params[:admin2_name] = source['admin2_name']
      end
      self.update(params)
    end

    def set_admin_names
      country = country_codes[country_code]
      self.country_name = country[:name] if country
      admin1 = admin1_codes["#{country_code}.#{admin1_code}"]
      self.admin1_name = admin1[:name] if admin1
      admin2 = admin2_codes["#{country_code}.#{admin1_code}.#{admin2_code}"]
      self.admin2_name = admin2[:name] if admin2
    end

    def country_codes
      @@country_codes ||= YAML::load(File.open('data/geonames/countries.yml'))
    end

    def admin1_codes
      @@admin1_codes ||= YAML::load(File.open('data/geonames/admin1.yml'))
    end

    def admin2_codes
      @@admin2_codes ||= YAML::load(File.open('data/geonames/admin2.yml'))
    end

    def generate_suggestions
    end

    def to_hash
      hash ={}
      self.instance_variables.each do |var|
        hash[var.to_s.delete("@")] = self.instance_variable_get(var)
      end
      hash.delete_if { |k,v| v=='' || v.nil? || (v.is_a?(Array) && v.empty?) }
      hash
    end

    def closest_geoname
      begin
        # try for a geoname with a matching name & type
        results = ES_CLIENT.search(index: INDEX, type: 'geoname', body: {
          query: {
            filtered: {
              query: {
                bool: {
                  must: [
                    match: { name: name.force_encoding('UTF-8') }
                  ],
                  should: [
                    match: { feature_class: 'P' }
                  ]
                }
              },
              filter: {
                geo_shape: {
                  center_shape: {
                    shape: boundaries,
                    relation: 'intersects'
                  }
                }
              }
            }
          }
        })
        # if not try any in boundaries
        if results['hits']['total'] == 0
          results = ES_CLIENT.search(index: INDEX, type: 'geoname', body: {
            query: {
              filtered: {
                query: { match_all: {} },
                filter: {
                  geo_shape: {
                    center_shape: {
                      shape: boundaries,
                      relation: 'intersects'
                    }
                  }
                }
              }
            }
          })
        end
        if result = results['hits']['hits'].first
          geoname = Pelias::Geoname.new(:id=>result['_id'])
          geoname.update(result['_source'])
          geoname
        else
          nil
        end
      rescue
        nil
      end
    end

    private

    def encompassing_shape(shape_type)
      results = ES_CLIENT.search(index: INDEX, type: shape_type, body: {
        query: {
          filtered: {
            query: { match_all: {} },
            filter: {
              geo_shape: {
                boundaries: {
                  shape: center_shape,
                  relation: 'intersects'
                }
              }
            }
          }
        }
      })
      results['hits']['hits'].first
    end

    def set_instance_variables(params)
      params.keys.each do |key|
        m = "#{key.to_s}="
        self.send(m, params[key]) if self.respond_to?(m)
      end
      true
    end

    def symbolize_keys(hash)
      hash.keys.each do |key|
        hash[(key.to_sym rescue key) || key] = hash.delete(key)
      end
    end

    def type
      self.class.type
    end

    def geo_query
      {
        query: {
          filtered: {
            query: { match_all: {} },
            filter: {
              geo_shape: {
                center_shape: {
                  indexed_shape: {
                    id: @id,
                    type: type,
                    index: INDEX,
                    shape_field_name: 'boundaries'
                  }
                }
              }
            }
          }
        }
      }
    end

  end

end
