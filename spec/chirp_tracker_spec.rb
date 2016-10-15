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

  context 'GET /zzz' do
    it 'responds with the requested amount of zzz' do
      get '/zzz?kb=1'
      expect(last_response.status).to eq(200)
      expect(last_response.body.length).to eq(1000)
    end

    it 'requires kb param' do
      get '/zzz'
      expect(last_response.status).to eq(400)
      expect(last_response.body).to match(/missing kb param/)
    end

    it 'rejects requests over max kb' do
      get '/zzz?kb=999999999'
      expect(last_response.status).to eq(400)
      expect(last_response.body).to match(/too much kb/)
    end
  end

  context 'POST /zzz' do
    let :upload_file do
      f = Tempfile.new('data')
      f.write(data)
      f.close
      f
    end

    let(:data) { 'z' * 1000 * kb }
    let(:kb) { rand(1..9) }

    it 'responds 201 when sizes match' do
      expect_any_instance_of(app).to receive(:log).with(
        message: 'received file upload', path: anything, size_kb: anything
      )
      zzz = Rack::Test::UploadedFile.new(
        upload_file.path, 'application/octet-stream'
      )
      post "/zzz?kb=#{kb}", 'zzz' => zzz
      expect(last_response.status).to eq(201)
      expect(last_response.body).to match(/wow/)
    end

    it 'requires kb param' do
      post '/zzz', ''
      expect(last_response.status).to eq(400)
      expect(last_response.body).to match(/missing kb param/)
    end

    it 'requires zzz param' do
      post '/zzz?kb=1', ''
      expect(last_response.status).to eq(400)
      expect(last_response.body).to match(/missing zzz param/)
    end

    it 'responds 400 when sizes do not match' do
      expect_any_instance_of(app).to receive(:log).with(
        message: 'received file upload', path: anything, size_kb: anything
      )
      zzz = Rack::Test::UploadedFile.new(
        upload_file.path, 'application/octet-stream'
      )
      post "/zzz?kb=#{kb + 1}", 'zzz' => zzz
      expect(last_response.status).to eq(400)
      expect(last_response.body).to match(/mismatched size/)
    end
  end
end
