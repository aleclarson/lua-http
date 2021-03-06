describe("low level http 1 connection operations", function()
	local h1_connection = require "http.h1_connection"
	local cqueues = require "cqueues"
	local ca = require "cqueues.auxlib"
	local cs = require "cqueues.socket"
	local ce = require "cqueues.errno"
	it("cannot construct with invalid type", function()
		local s, c = ca.assert(cs.pair())
		assert.has.errors(function() h1_connection.new(s, nil, 1.1) end)
		assert.has.errors(function() h1_connection.new(s, "", 1.1) end)
		assert.has.errors(function() h1_connection.new(s, "invalid", 1.1) end)
		s:close()
		c:close()
	end)
	it("__tostring works", function()
		local s, c = ca.assert(cs.pair())
		local h = h1_connection.new(c, "client", 1.1)
		assert.same("http.h1_connection{", tostring(h):match("^.-%{"))
		s:close()
		h:close()
	end)
	local function new_pair(version)
		local s, c = ca.assert(cs.pair())
		s = h1_connection.new(s, "server", version)
		c = h1_connection.new(c, "client", version)
		return s, c
	end
	it(":take_socket works", function()
		local s, c = new_pair(1.1)
		local sock = s:take_socket()
		assert.same("socket", cs.type(sock))
		-- 2nd time it should return nil
		assert.same(nil, s:take_socket())
		sock:close()
		c:close()
	end)
	it(":localname and :peername work", function()
		do
			local s, c = new_pair(1.1)
			-- these are unnamed sockets; so 2nd return should be `nil`
			assert.same({cs.AF_UNIX, nil}, {s:localname()})
			assert.same({cs.AF_UNIX, nil}, {s:peername()})
			assert.same({cs.AF_UNIX, nil}, {c:localname()})
			assert.same({cs.AF_UNIX, nil}, {c:peername()})
			s:close()
			c:close()
		end
		do
			local s, c = new_pair(1.1)
			s:take_socket():close() -- take out socket (and discard)
			c:close()
			assert.same({nil}, {s:localname()})
			assert.same({nil}, {s:peername()})
		end
	end)
	-- Pending as ECONNRESET behaviour is unportable
	pending("persists errors (except ETIMEDOUT) until cleared", function()
		local s, c = new_pair(1.1)
		assert.same(ce.ETIMEDOUT, select(3, s:read_request_line(0)))
		assert(s:write_status_line(1.0, "100", "continue", TEST_TIMEOUT))
		assert(s:flush(TEST_TIMEOUT))
		c:close()
		assert.same(ce.ECONNRESET, select(3, s:read_request_line(0)))
		assert.same(ce.ECONNRESET, select(3, s:read_request_line(0)))
		s:clearerr()
		assert.same({nil, nil}, {s:read_request_line(0)})
		s:close()
	end)
	it(":clearerr doesn't throw when socket is gone", function()
		local s, c = new_pair(1.1)
		c:close()
		s:take_socket():close() -- take out socket (and discard)
		s:clearerr()
	end)
	it("persisted errors don't leave socket as readable", function()
		local s, c = new_pair(1.1)
		c = c:take_socket()
		assert(c:xwrite("INVALID REQUEST\r\n", "n", TEST_TIMEOUT))
		local first_stream = assert(s:get_next_incoming_stream(TEST_TIMEOUT))
		assert.same(ce.EILSEQ, select(3, first_stream:get_headers(TEST_TIMEOUT)))
		first_stream:shutdown()
		assert.same(ce.EILSEQ, select(3, s:get_next_incoming_stream(TEST_TIMEOUT)))
		assert.same(ce.EILSEQ, select(3, s:read_request_line(TEST_TIMEOUT)))
		s:close()
		c:close()
	end)
	it("request line should round trip", function()
		local function test(req_method, req_path, req_version)
			local s, c = new_pair(req_version)
			assert(c:write_request_line(req_method, req_path, req_version))
			assert(c:flush())
			local res_method, res_path, res_version = assert(s:read_request_line())
			assert.same(req_method, res_method)
			assert.same(req_path, res_path)
			assert.same(req_version, res_version)
			s:close()
			c:close()
		end
		test("GET", "/", 1.1)
		test("POST", "/foo", 1.0)
		test("OPTIONS", "*", 1.1)
	end)
	it(":write_request_line parameters should be validated", function()
		local s, c = new_pair(1.1)
		assert.has.errors(function() s:write_request_line("", "/foo", 1.0) end)
		assert.has.errors(function() s:write_request_line("GET", "", 1.0) end)
		assert.has.errors(function() s:write_request_line("GET", "/", 0) end)
		assert.has.errors(function() s:write_request_line("GET", "/", 2) end)
		s:close()
		c:close()
	end)
	it(":read_request_line should fail on invalid request", function()
		local function test(chunk)
			local s, c = new_pair(1.1)
			s = s:take_socket()
			assert(s:xwrite(chunk, "n", TEST_TIMEOUT))
			s:close()
			assert.same(ce.EILSEQ, select(3, c:read_request_line(TEST_TIMEOUT)))
			c:close()
		end
		test("GET") -- no \r\n
		test("\r\nGET") -- no \r\n with preceeding \r\n
		test("invalid request line\r\n")
		test(" / HTTP/1.1\r\n")
		test("\r\n / HTTP/1.1\r\n")
		test("HTTP/1.1\r\n")
		test("GET HTTP/1.0\r\n")
		test("GET  HTTP/1.0\r\n")
		test("GET HTTP/1.0\r\n")
		test("GET / HTP/1.1\r\n")
		test("GET / HTTP 1.1\r\n")
		test("GET / HTTP/1\r\n")
		test("GET / HTTP/2.0\r\n")
		test("GET / HTTP/1.1\nHeader: value\r\n") -- missing \r
	end)
	it(":read_request_line should allow a leading CRLF", function()
		local function test(chunk)
			local s, c = new_pair(1.1)
			s = s:take_socket()
			assert(s:xwrite(chunk, "n"))
			assert(c:read_request_line())
			s:close()
			c:close()
		end
		test("\r\nGET / HTTP/1.1\r\n")
	end)
	describe("overlong lines", function()
		it(":read_request_line", function()
			local s, c = new_pair(1.1)
			s = s:take_socket()
			assert(s:xwrite(("a"):rep(10000), "n"))
			assert.same(ce.EILSEQ, select(3, c:read_request_line(TEST_TIMEOUT)))
			s:close()
			c:close()
		end)
		it(":read_status_line", function()
			local s, c = new_pair(1.1)
			s = s:take_socket()
			assert(s:xwrite(("a"):rep(10000), "n"))
			assert.same(ce.EILSEQ, select(3, c:read_status_line(TEST_TIMEOUT)))
			s:close()
			c:close()
		end)
		it(":read_header", function()
			local s, c = new_pair(1.1)
			s = s:take_socket()
			assert(s:xwrite(("a"):rep(10000), "n"))
			assert.same(ce.EILSEQ, select(3, c:read_header(TEST_TIMEOUT)))
			s:close()
			c:close()
		end)
		it(":read_body_chunk", function()
			local s, c = new_pair(1.1)
			s = s:take_socket()
			assert(s:xwrite(("a"):rep(10000), "n"))
			assert.same(ce.EILSEQ, select(3, c:read_body_chunk(TEST_TIMEOUT)))
			s:close()
			c:close()
		end)
	end)
	it("status line should round trip", function()
		local function test(req_version, req_status, req_reason)
			local s, c = new_pair(req_version)
			assert(s:write_status_line(req_version, req_status, req_reason))
			assert(s:flush())
			local res_version, res_status, res_reason = assert(c:read_status_line())
			assert.same(req_version, res_version)
			assert.same(req_status, res_status)
			assert.same(req_reason, res_reason)
			s:close()
			c:close()
		end
		test(1.1, "200", "OK")
		test(1.0, "404", "Not Found")
		test(1.1, "200", "")
		test(1.1, "999", "weird\1\127and wonderful\4bytes")
	end)
	it(":write_status_line parameters should be validated", function()
		local s, c = new_pair(1.1)
		assert.has.errors(function() s:write_status_line(nil, "200", "OK") end)
		assert.has.errors(function() s:write_status_line(0, "200", "OK") end)
		assert.has.errors(function() s:write_status_line(2, "200", "OK") end)
		assert.has.errors(function() s:write_status_line(math.huge, "200", "OK") end)
		assert.has.errors(function() s:write_status_line("not a number", "200", "OK") end)
		assert.has.errors(function() s:write_status_line(1.1, "", "OK") end)
		assert.has.errors(function() s:write_status_line(1.1, "1000", "OK") end)
		assert.has.errors(function() s:write_status_line(1.1, 200, "OK") end)
		assert.has.errors(function() s:write_status_line(1.1, "200", "new lines\r\n") end)
		s:close()
		c:close()
	end)
	it(":read_status_line should return EILSEQ on invalid status line", function()
		local function test(chunk)
			local s, c = new_pair(1.1)
			s = s:take_socket()
			assert(s:write(chunk, "\r\n"))
			assert(s:flush())
			assert.same(ce.EILSEQ, select(3, c:read_status_line()))
			s:close()
			c:close()
		end
		test("invalid status line")
		test("HTTP/0 200 OK")
		test("HTTP/0.0 200 OK")
		test("HTTP/2.0 200 OK")
		test("HTTP/1 200 OK")
		test("HTTP/.1 200 OK")
		test("HTP/1.1 200 OK")
		test("1.1 200 OK")
		test(" 200 OK")
		test("200 OK")
		test("HTTP/1.1 0 OK")
		test("HTTP/1.1 1000 OK")
		test("HTTP/1.1  OK")
		test("HTTP/1.1 OK")
		test("HTTP/1.1 200")
		test("HTTP/1.1 200 OK\nHeader: value") -- missing \r
	end)
	it(":read_status_line should return nil on EOF", function()
		local s, c = new_pair(1.1)
		s:close()
		assert.same({nil, nil}, {c:read_status_line()})
		c:close()
	end)
	it("headers should round trip", function()
		local function test(input)
			local s, c = new_pair(1.1)

			assert(c:write_request_line("GET", "/", 1.1))
			for _, t in ipairs(input) do
				assert(c:write_header(t[1], t[2]))
			end
			assert(c:write_headers_done())

			assert(s:read_request_line())
			for _, t in ipairs(input) do
				local k, v = assert(s:read_header())
				assert.same(t[1], k)
				assert.same(t[2], v)
			end
			assert(s:read_headers_done())
			s:close()
			c:close()
		end
		test{}
		test{
			{"foo", "bar"};
		}
		test{
			{"Host", "example.com"};
			{"User-Agent", "some user/agent"};
			{"Accept", "*/*"};
		}
	end)
	it(":read_header works in exotic conditions", function()
		do -- trailing whitespace
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("foo: bar \r\n\r\n", "bn"))
			c:close()
			assert.same({"foo", "bar"}, {s:read_header()})
			s:close()
		end
		do -- continuation
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("foo: bar\r\n qux\r\n\r\n", "bn"))
			c:close()
			assert.same({"foo", "bar qux"}, {s:read_header()})
			s:close()
		end
		do -- not a continuation, but only partial next header
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("foo: bar\r\npartial", "bn"))
			c:close()
			assert.same({"foo", "bar"}, {s:read_header()})
			s:close()
		end
		do -- not a continuation as gets a single byte of EOH
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("foo: bar\r\n\r", "bn"))
			c:close()
			assert.same({"foo", "bar"}, {s:read_header()})
			s:close()
		end
		do -- trickle
			local s, c = new_pair(1.1)
			c = c:take_socket()
			local cq = cqueues.new();
			cq:wrap(function()
				for char in ("foo: bar\r\n\r\n"):gmatch(".") do
					assert(c:xwrite(char, "bn"))
					cqueues.sleep(0.01)
				end
			end)
			cq:wrap(function()
				assert.same({"foo", "bar"}, {s:read_header()})
			end)
			assert(cq:loop())
			s:close()
			c:close()
		end
	end)
	describe(":read_header failure conditions", function()
		it("handles no data", function()
			local s, c = new_pair(1.1)
			c:close()
			assert.same({nil, nil}, {s:read_header()})
			s:close()
		end)
		it("handles sudden connection close", function()
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("foo", "bn"))
			c:close()
			assert.same(ce.EILSEQ, select(3, s:read_header()))
			s:close()
		end)
		it("handles sudden connection close after field name", function()
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("foo:", "bn"))
			c:close()
			assert.same(ce.EILSEQ, select(3, s:read_header()))
			s:close()
		end)
		it("handles sudden connection close after :", function()
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("foo: ba", "bn"))
			c:close()
			assert.same(ce.EILSEQ, select(3, s:read_header()))
			s:close()
		end)
		it("handles has carriage return but no new line", function()
			-- unknown if it was going to be a header continuation or not
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("foo: bar\r", "bn"))
			c:close()
			assert.same(ce.EILSEQ, select(3, s:read_header()))
			s:close()
		end)
		it("handles closed after new line", function()
			-- unknown if it was going to be a header continuation or not
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("foo: bar\r\n", "bn"))
			c:close()
			assert.same(ce.EILSEQ, select(3, s:read_header()))
			s:close()
		end)
		it("handles timeout", function()
			local s, c = new_pair(1.1)
			assert.same(ce.ETIMEDOUT, select(3, s:read_header(0.01)))
			s:close()
			c:close()
		end)
		-- Pending as ECONNRESET behaviour is unportable
		pending("handles connection reset", function()
			local s, c = new_pair(1.1)
			assert(s:write_body_plain("something that flushes"))
			c:close()
			assert.same({nil, "read: Connection reset by peer", ce.ECONNRESET}, {s:read_header()})
			s:close()
		end)
		it("disallows whitespace before :", function()
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("foo : bar\r\n\r\n", "bn"))
			c:close()
			assert.same(ce.EILSEQ, select(3, s:read_header()))
			s:close()
		end)
		it("handles no field name", function()
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite(": fs\r\n\r\n", "bn"))
			c:close()
			assert.same(ce.EILSEQ, select(3, s:read_header()))
			s:close()
		end)
		it("handles no colon", function()
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("foo bar\r\n\r\n", "bn"))
			c:close()
			assert.same(ce.EILSEQ, select(3, s:read_header()))
			s:close()
		end)
	end)
	describe(":read_headers_done should handle failure conditions", function()
		it("no data", function()
			local s, c = new_pair(1.1)
			c:close()
			assert.same({nil, nil}, {s:read_headers_done()})
			s:close()
		end)
		it("sudden connection close", function()
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("\r", "bn"))
			c:close()
			assert.same(ce.EILSEQ, select(3, s:read_headers_done()))
			s:close()
		end)
		it("timeout", function()
			local s, c = new_pair(1.1)
			assert.same(ce.ETIMEDOUT, select(3, s:read_headers_done(0.01)))
			s:close()
			c:close()
		end)
		-- Pending as ECONNRESET behaviour is unportable
		pending("connection reset", function()
			local s, c = new_pair(1.1)
			assert(s:write_body_plain("something that flushes"))
			c:close()
			assert.same({nil, "read: Connection reset by peer", ce.ECONNRESET}, {s:read_headers_done()})
			s:close()
		end)
		it("wrong byte", function()
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("\0", "bn"))
			c:close()
			assert.same(ce.EILSEQ, select(3, s:read_headers_done()))
			s:close()
		end)
		it("wrong bytes", function()
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("hi", "bn"))
			c:close()
			assert.same(ce.EILSEQ, select(3, s:read_headers_done()))
			s:close()
		end)
	end)
	it(":write_header accepts odd fields", function()
		local s, c = new_pair(1.1)
		assert(s:write_header("foo", "bar"))
		assert(s:write_header("foo", " bar"))
		assert(s:write_header("foo", "bar "))
		assert(s:write_header("foo", "bar: stuff"))
		assert(s:write_header("foo", "bar, stuff"))
		assert(s:write_header("foo", "bar\n continuation"))
		assert(s:write_header("foo", "bar\r\n continuation"))
		assert(s:write_header("foo", "bar\r\n continuation: with colon"))
		c:close()
		s:close()
	end)
	it(":write_header rejects invalid headers", function()
		local s, c = new_pair(1.1)
		assert.has.errors(function() s:write_header() end)
		-- odd field names
		assert.has.errors(function() s:write_header(nil, "bar") end)
		assert.has.errors(function() s:write_header(":", "bar") end)
		assert.has.errors(function() s:write_header("\n", "bar") end)
		assert.has.errors(function() s:write_header("foo\r\n", "bar") end)
		assert.has.errors(function() s:write_header("f\r\noo", "bar") end)
		-- odd values
		assert.has.errors(function() s:write_header("foo") end)
		assert.has.errors(function() s:write_header("foo", "bar\r\n") end)
		assert.has.errors(function() s:write_header("foo", "bar\r\n\r\n") end)
		assert.has.errors(function() s:write_header("foo", "bar\nbad continuation") end)
		assert.has.errors(function() s:write_header("foo", "bar\r\nbad continuation") end)
		s:close()
		c:close()
	end)
	it("chunks round trip", function()
		local s, c = new_pair(1.1)
		assert(c:write_request_line("POST", "/", 1.1))
		assert(c:write_header("Transfer-Encoding", "chunked"))
		assert(c:write_headers_done())
		assert(c:write_body_chunk("this is a chunk"))
		assert(c:write_body_chunk("this is another chunk"))
		assert(c:write_body_last_chunk())
		assert(c:write_headers_done())

		assert(s:read_request_line())
		assert(s:read_header())
		assert(s:read_headers_done())
		assert.same("this is a chunk", s:read_body_chunk())
		assert.same("this is another chunk", s:read_body_chunk())
		assert.same(false, s:read_body_chunk())
		assert(s:read_headers_done())
		s:close()
		c:close()
	end)
	it(":read_body_chunk doesn't consume input on failure", function()
		local s, c = new_pair(1.1)
		c = c:take_socket()
		assert(c:xwrite("6", "n"))
		assert.same(ce.ETIMEDOUT, select(3, s:read_body_chunk(0.01)))
		s:clearerr()
		assert(c:xwrite("\r\nfoo", "n"))
		assert.same(ce.ETIMEDOUT, select(3, s:read_body_chunk(0.01)))
		s:clearerr()
		assert(c:xwrite("bar\r\n", "n"))
		assert.same({"foobar"}, {s:read_body_chunk(0.001)})
		assert(c:xwrite("0", "n"))
		assert.same(ce.ETIMEDOUT, select(3, s:read_body_chunk(0.01)))
		s:clearerr()
		assert(c:xwrite("\r", "n"))
		assert.same(ce.ETIMEDOUT, select(3, s:read_body_chunk(0.01)))
		s:clearerr()
		assert(c:xwrite("\n", "n"))
		assert.same({false}, {s:read_body_chunk(0.001)})
		s:close()
		c:close()
	end)
	it(":read_body_chunk fails on invalid chunk", function()
		local function test(chunk, expected_errno)
			local s, c = new_pair(1.1)
			s = s:take_socket()
			assert(s:xwrite(chunk, "n", TEST_TIMEOUT))
			s:close()
			local data, _, errno = c:read_body_chunk(TEST_TIMEOUT)
			assert.same(nil, data)
			assert.same(expected_errno, errno)
			c:close()
		end
		test("", nil)
		test("5", ce.EILSEQ)
		test("5\r", ce.EILSEQ)
		test("fffffffffffffff\r\n", ce.E2BIG)
		test("not a number\r\n", ce.EILSEQ)
		test("4\r\n1", ce.EILSEQ)
		test("4\r\nfour\n", ce.EILSEQ)
		test("4\r\nlonger than four", ce.EILSEQ)
		test("4\r\nfour\nmissing \r", ce.EILSEQ)
	end)
	it(":read_body_chunk is cqueues thread-safe", function()
		local s, c = new_pair(1.1)
		s = s:take_socket()
		local cq = cqueues.new()
		cq:wrap(function()
			local chunk = assert(c:read_body_chunk())
			assert.same("bytes", chunk)
		end)
		cq:wrap(function()
			assert(s:xwrite("5\r\n", "bn"))
			cqueues.sleep(0.001) -- let other thread block on reading chunk body
			assert(s:xwrite("chars\r\n", "bn"))
			local chunk = assert(c:read_body_chunk())
			assert.same("chars", chunk)
			-- send a 2nd frame
			assert(s:xwrite("5\r\nbytes\r\n", "bn"))
			s:close()
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		c:close()
	end)
end)
describe("high level http1 connection operations", function()
	local h1_connection = require "http.h1_connection"
	local ca = require "cqueues.auxlib"
	local ce = require "cqueues.errno"
	local cs = require "cqueues.socket"

	local function new_pair(version)
		local s, c = ca.assert(cs.pair())
		s = h1_connection.new(s, "server", version)
		c = h1_connection.new(c, "client", version)
		return s, c
	end

	it(":shutdown('r') shouldn't shutdown streams that have been read", function()
		local s, c = new_pair(1.1) -- luacheck: ignore 211
		assert(c:write_request_line("GET", "/", 1.0))
		assert(c:write_headers_done())
		assert(c:write_request_line("GET", "/", 1.0))
		assert(c:write_headers_done())
		local stream1 = assert(s:get_next_incoming_stream())
		assert(stream1:read_headers())
		local stream2 = assert(s:get_next_incoming_stream())
		assert.same("idle", stream2.state)
		s:shutdown("r")
		assert.same("idle", stream2.state)
		s:close()
		c:close()
	end)
	it(":get_next_incoming_stream times out", function()
		local s, c = new_pair(1.1) -- luacheck: ignore 211
		assert.same(ce.ETIMEDOUT, select(3, s:get_next_incoming_stream(0.05)))
		s:close()
		c:close()
	end)
	it(":get_next_incoming_stream returns nil when no data", function()
		local s, c = new_pair(1.1)
		c:close()
		-- perform a read operation so we note the EOF
		assert.same({nil, nil}, {s:read_status_line()})
		-- now waiting for a stream should also return EOF
		assert.same({nil, nil}, {s:get_next_incoming_stream()})
		s:close()
	end)
end)
