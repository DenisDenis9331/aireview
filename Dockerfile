FROM ruby:3.1.3-alpine

RUN apk add --no-cache build-base git

RUN gem install bundler:2.3.26

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle _2.3.26_ install

COPY . .

ENTRYPOINT ["bundle", "_2.3.26_", "exec", "bin/aireview"]
CMD ["--help"]
