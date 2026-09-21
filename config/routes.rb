DiscourseRsdate::Engine.routes.draw do
    get "/" => "main#index"
    get "/state" => "main#state"
    post "/action" => "main#mutate"
    get "/export" => "main#export"
    get "/legacy(/*path)" => "main#legacy"
  end
