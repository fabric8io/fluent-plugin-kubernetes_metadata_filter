FROM ruby

ADD . /plugin

WORKDIR /plugin

RUN apt update && apt install -y build-essential cmake

RUN bundle install

CMD rake test
