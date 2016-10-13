# frozen_string_literal: true
describe 'Chirp Tracker' do
  def app
    ChirpTracker
  end

  context 'POST /stats' do
    it 'forwards stats to logs' do
      expect_any_instance_of(app).to receive(:log).with(
        'sample#chirp.unknown.unknown.test' => '1.5s'
      )
      post '/stats', '{"data":[{"script":"test","exe_time":"1.5s"}]}'
      expect(last_response.status).to eq(200)
    end

    it 'accepts empty data' do
      post '/stats', '{"data":[]}'
      expect(last_response.status).to eq(200)
    end

    it 'rejects invalid JSON' do
      post '/stats', '{nope'
      expect(last_response.status).to eq(400)
    end

    it 'rejects payloads lacking "data"' do
      post '/stats', '{"nope":""}'
      expect(last_response.status).to eq(400)
    end

    it 'rejects payloads with invalid record format' do
      post '/stats', '{"data":[{"nope":1}]}'
      expect(last_response.status).to eq(400)
    end
  end
end
