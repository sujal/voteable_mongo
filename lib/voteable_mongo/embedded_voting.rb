module Mongo
  module Voteable
    module EmbeddedVoting
      extend ActiveSupport::Concern
      
      module ClassMethods

        # Make a vote on an object of this class
        #
        # @param [Hash] options a hash containings:
        #   - :votee_id: the votee document id
        #   - :voter_id: the voter document id
        #   - :value: :up or :down
        #   - :revote: if true change vote vote from :up to :down and vise versa
        #   - :unvote: if true undo the voting
        # 
        # @return [votee, false]
        def vote(options)
          validate_and_normalize_vote_options(options)
          options[:voteable] = VOTEABLE[name][name]
          
          if options[:voteable]
             query, update = if options[:revote]
              revote_query_and_update(options)
            elsif options[:unvote]
              unvote_query_and_update(options)
            else
              new_vote_query_and_update(options)
            end

            # http://www.mongodb.org/display/DOCS/findAndModify+Command
            begin
              doc = voteable_collection.find_and_modify(
                :query => query,
                :update => update,
                :new => true
              )
            rescue Mongo::OperationFailure => e
              doc = nil
            end  

            if doc
              update_parent_votes(doc, options) if options[:voteable][:update_parents]
              # Update new votes data
              
              filtered = doc[self.voteable_embedded_collection_name].select do |item|
                item["_id"] == options[:votee].try(:id) || item["_id"] == options[:votee_id]
              end
              
              if filtered && filtered.length > 0
                options[:votee].write_attribute('votes', filtered[0]["votes"]) if options[:votee]
                options[:votee] || new(filtered[0])                
              end
            else
              false
            end
          end
        end

        
        private
          def validate_and_normalize_vote_options(options)
            options.symbolize_keys!
            options[:parent_doc_id] = Helpers.try_to_convert_string_to_object_id(options[:parent_doc_id])
            if options[:parent_doc_id].nil?
              raise "parent doc id is required for embedded models"
            end
            options[:votee_id] = Helpers.try_to_convert_string_to_object_id(options[:votee_id])
            options[:voter_id] = Helpers.try_to_convert_string_to_object_id(options[:voter_id])
            options[:value] &&= options[:value].to_sym
          end
        
          def new_vote_query_and_update(options)
            
            subcollection_positional_prefix = "#{self.voteable_embedded_collection_name}.$."
            subcollection_prefix = self.voteable_embedded_collection_name
            
            if options[:value] == :up
              positive_voter_ids = "#{subcollection_positional_prefix}votes.up"
              positive_votes_count = "#{subcollection_positional_prefix}votes.up_count"
            else
              positive_voter_ids = "#{subcollection_positional_prefix}votes.down"
              positive_votes_count = "#{subcollection_positional_prefix}votes.down_count"
            end

            return {
              # Validate voter_id did not vote for votee_id yet
              :_id => options[:parent_doc_id],
              subcollection_prefix => {
                "$elemMatch" => {
                  "_id" => options[:votee_id],
                  "votes.up" => { '$ne' => options[:voter_id] },
                  "votes.down" => { '$ne' => options[:voter_id] }
                }
              }
            }, {
              # then update
              '$push' => { positive_voter_ids => options[:voter_id] },
              '$inc' => {
                "#{subcollection_positional_prefix}votes.count" => +1,
                positive_votes_count => +1,
                "#{subcollection_positional_prefix}votes.point" => options[:voteable][options[:value]]
              }
            }
          end

          
          def revote_query_and_update(options)
            
            subcollection_positional_prefix = "#{self.voteable_embedded_collection_name}.$."
            subcollection_prefix = self.voteable_embedded_collection_name
            
            if options[:value] == :up
              positive_voter_ids = "votes.up"
              negative_voter_ids = "votes.down"
              positive_votes_count = "#{subcollection_positional_prefix}votes.up_count"
              negative_votes_count = "#{subcollection_positional_prefix}votes.down_count"
              point_delta = options[:voteable][:up] - options[:voteable][:down]
            else
              positive_voter_ids = "votes.down"
              negative_voter_ids = "votes.up"
              positive_votes_count = "#{subcollection_positional_prefix}votes.down_count"
              negative_votes_count = "#{subcollection_positional_prefix}votes.up_count"
              point_delta = -options[:voteable][:up] + options[:voteable][:down]
            end

            return {
              # Validate voter_id did a vote with value for votee_id
              :_id => options[:parent_doc_id],
              "#{subcollection_prefix}" => {
                "$elemMatch" => {
                  "_id" => options[:votee_id],
                  # Can skip $ne validation since creating a new vote
                  # already warranty that a voter can vote one only
                  # positive_voter_ids => { '$ne' => options[:voter_id] },
                  negative_voter_ids => options[:voter_id]                  
                }
              }
            }, {
              # then update
              '$pull' => { "#{subcollection_positional_prefix}#{negative_voter_ids}" => options[:voter_id] },
              '$push' => { "#{subcollection_positional_prefix}#{positive_voter_ids}" => options[:voter_id] },
              '$inc' => {
                positive_votes_count => +1,
                negative_votes_count => -1,
                "#{subcollection_positional_prefix}votes.point" => point_delta
              }
            }
          end
          

          def unvote_query_and_update(options)
            
            subcollection_positional_prefix = "#{self.voteable_embedded_collection_name}.$."
            subcollection_prefix = self.voteable_embedded_collection_name
            
            if options[:value] == :up
              positive_voter_ids = "votes.up"
              negative_voter_ids = "votes.down"
              positive_votes_count = "#{subcollection_positional_prefix}votes.up_count"
            else
              positive_voter_ids = "votes.down"
              negative_voter_ids = "votes.up"
              positive_votes_count = "#{subcollection_positional_prefix}votes.down_count"
            end

            return {
              :_id => options[:parent_doc_id],
              subcollection_prefix => {
                "$elemMatch" => {
                  "_id" => options[:votee_id],
                  # Validate if voter_id did a vote with value for votee_id
                  # Can skip $ne validation since creating a new vote 
                  # already warranty that a voter can vote one only
                  # negative_voter_ids => { '$ne' => options[:voter_id] },
                  positive_voter_ids => options[:voter_id]                
                }
              }
            }, {
              # then update
              '$pull' => { "#{subcollection_positional_prefix}#{positive_voter_ids}" => options[:voter_id] },
              '$inc' => {
                positive_votes_count => -1,
                "#{subcollection_positional_prefix}votes.count" => -1,
                "#{subcollection_positional_prefix}votes.point" => -options[:voteable][options[:value]]
              }
            }
          end
          

          def update_parent_votes(doc, options)
            
            raise "parent voting unsupported for embedded documents (yet!)"
            # VOTEABLE[name].each do |class_name, voteable|
            #   if metadata = voteable_relation(class_name)
            #     if (parent_id = doc[voteable_foreign_key(metadata)]).present?
            #       parent_ids = parent_id.is_a?(Array) ? parent_id : [ parent_id ]
            #       class_name.constantize.collection.update( 
            #         { '_id' => { '$in' => parent_ids } },
            #         { '$inc' => parent_inc_options(voteable, options) },
            #         { :multi => true }
            #       )
            #     end
            #   end
            # end
          end

          
          # def parent_inc_options(voteable, options)
          #   inc_options = {}
          # 
          #   if options[:revote]
          #     if options[:value] == :up
          #       inc_options['votes.point'] = voteable[:up] - voteable[:down]
          #       unless voteable[:update_counters] == false
          #         inc_options['votes.up_count'] = +1
          #         inc_options['votes.down_count'] = -1
          #       end
          #     else
          #       inc_options['votes.point'] = -voteable[:up] + voteable[:down]
          #       unless voteable[:update_counters] == false
          #         inc_options['votes.up_count'] = -1
          #         inc_options['votes.down_count'] = +1
          #       end
          #     end
          # 
          #   elsif options[:unvote]
          #     inc_options['votes.point'] = -voteable[options[:value]]
          #     unless voteable[:update_counters] == false
          #       inc_options['votes.count'] = -1
          #       if options[:value] == :up
          #         inc_options['votes.up_count'] = -1
          #       else
          #         inc_options['votes.down_count'] = -1
          #       end
          #     end
          # 
          #   else # new vote
          #     inc_options['votes.point'] = voteable[options[:value]]
          #     unless voteable[:update_counters] == false
          #       inc_options['votes.count'] = +1
          #       if options[:value] == :up
          #         inc_options['votes.up_count'] = +1
          #       else
          #         inc_options['votes.down_count'] = +1
          #       end
          #     end
          #   end
          # 
          #   inc_options
          # end
      end
            
    end
  end
end
