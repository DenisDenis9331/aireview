FROM ruby:4.0.10-alpine

RUN apk add --no-cache build-base git

WORKDIR /app

COPY Gemfile Gemfile.lock aireview.gemspec ./
COPY lib/aireview/version.rb lib/aireview/version.rb
RUN bundle install

COPY . .

ENV AIREVIEW_DEFAULTS=/app/config/defaults.yml

ENTRYPOINT ["bundle", "exec", "bin/aireview"]
CMD ["--help"]
