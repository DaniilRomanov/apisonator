require_relative '../../spec_helper'
require_relative '../../../lib/3scale/backend/stats/kinesis_adapter'

module ThreeScale
  module Backend
    module Stats
      describe KinesisAdapter do
        let(:kinesis_client) { double }
        let(:stream_name) { 'backend_stream' }
        let(:storage) { ThreeScale::Backend::Storage.instance }
        let(:events_per_record) { described_class.const_get(:EVENTS_PER_RECORD) }
        let(:max_records_per_batch) { described_class.const_get(:MAX_RECORDS_PER_BATCH) }
        let(:kinesis_pending_events_key) do
          described_class.const_get(:KINESIS_PENDING_EVENTS_KEY)
        end

        subject { described_class.new(stream_name, kinesis_client, storage) }

        describe '#send_events' do
          context 'when the number of events is smaller than the number of events per record' do
            let(:events) { generate_unique_events(events_per_record - 1) }

            before { expect(kinesis_client).not_to receive(:put_record_batch) }

            it 'does not send the events to Kinesis' do
              subject.send_events(events)
            end

            it 'adds the events as pending events' do
              subject.send_events(events)
              expect(subject.send(:stored_pending_events)).to match_array events
            end
          end

          context 'when the number of events is enough to fill just 1 record' do
            let(:events) { generate_unique_events(events_per_record) }

            before do
              expect(kinesis_client)
                  .to receive(:put_record_batch)
                          .with({ delivery_stream_name: stream_name,
                                  records: [{ data: events.to_json }] })
                          .and_return(failed_put_count: 0,
                                      request_responses: [{ record_id: 'id' }])
            end

            it 'sends the events to Kinesis' do
              subject.send_events(events)
            end

            it 'pending events is empty' do
              subject.send_events(events)
              expect(subject.send(:stored_pending_events)).to be_empty
            end
          end

          context 'when the number of events fills several records but can be sent in 1 batch' do
            let(:records) { 2 } # Assuming that a batch can contain at least 2 records
            let(:events) { generate_unique_events(records*events_per_record) }
            let(:kinesis_records) do
              [{ data: events[0..events_per_record - 1].to_json },
               { data: events[events_per_record..-1].to_json }]
            end

            before do
              expect(kinesis_client)
                  .to receive(:put_record_batch)
                          .with({ delivery_stream_name: stream_name,
                                  records: kinesis_records })
                          .and_return(failed_put_count: 0,
                                      request_responses: Array.new(records, { record_id: 'id' }))
            end

            it 'sends the events to Kinesis' do
              subject.send_events(events)
            end

            it 'pending events is empty' do
              subject.send_events(events)
              expect(subject.send(:stored_pending_events)).to be_empty
            end
          end

          context 'when the number of events is too big to be sent in just one batch' do
            let(:records) { max_records_per_batch + 1 }
            let(:events) { generate_unique_events(records*events_per_record) }
            let(:events_not_batched) do
              events.last((records - max_records_per_batch)*events_per_record)
            end
            let(:kinesis_records) do
              events.each_slice(events_per_record).map do |events_slice|
                { data: events_slice.to_json }
              end.take(max_records_per_batch)
            end

            before do
              expect(kinesis_client)
                  .to receive(:put_record_batch)
                          .with({ delivery_stream_name: stream_name,
                                  records: kinesis_records })
                          .and_return(failed_put_count: 0,
                                      request_responses: Array.new(max_records_per_batch,
                                                                   { record_id: 'id' }))
            end

            it 'sends a batch to Kinesis' do
              subject.send_events(events)
            end

            it 'pending events includes the events that did not fit in the batch' do
              subject.send_events(events)
              expect(subject.send(:stored_pending_events))
                  .to match_array events_not_batched
            end
          end

          context 'when Kinesis returns an error for some record' do
            let(:events) { generate_unique_events(2*events_per_record) }
            let(:first_record) { events[0..events_per_record - 1] }
            let(:second_record) { events[events_per_record..-1] }

            before do
              # return error for the second record
              expect(kinesis_client)
                  .to receive(:put_record_batch)
                          .with({ delivery_stream_name: stream_name,
                                  records: [{ data: first_record.to_json },
                                            { data: second_record.to_json }] })
                          .and_return(failed_put_count: 1,
                                      request_responses: [{ record_id: 'id' },
                                                          { error_code: 'err' }])
            end

            it 'the events of the failed record are stored in pending events' do
              subject.send_events(first_record + second_record)
              expect(subject.send(:stored_pending_events)).to match_array second_record
            end
          end
        end

        def generate_unique_events(n_events)
          (1..n_events).map do |i|
            { service: 's', metric: 'm', period: 'year', timestamp: '20150101', value: i }
          end
        end
      end
    end
  end
end
