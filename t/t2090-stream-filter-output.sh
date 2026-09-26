#!/bin/sh

test_description='streaming smudge filter output to the working tree

Every test that checks out filtered content is run both with
checkout.streamFilterOutput disabled and enabled, and must give the same
result in both modes.'

GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME=main
export GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME

. ./test-lib.sh

TEST_ROOT="$(pwd)"

write_script "$TEST_ROOT/rot13.sh" <<\EOF
tr \
  'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ' \
  'nopqrstuvwxyzabcdefghijklmNOPQRSTUVWXYZABCDEFGHIJKLM'
EOF

# The pkt-line payload limit; the sizes below straddle one and two
# packets' worth of content.
max=65516
SIZES="0 1 $((max - 1)) $max $((max + 1)) $((2 * max)) $((2 * max + 1)) 3000000"

# Write <size> bytes of text to <file>.
gen_text () {
	test-tool genrandom "seed-$1" | tr -dc 'a-zA-Z0-9\n' |
	test_copy_bytes "$1" >"$2"
}

# Add <path> to the index with exactly the contents of <file>, bypassing
# the clean filter.
add_raw () {
	blob=$(git hash-object -w --no-filters "$2") &&
	git update-index --add --cacheinfo "${3:-100644},$blob,$1"
}

# Remove the working tree files given and check them out again with the
# streaming mode in $1, logging filter traffic to filter.log.
checkout_with () {
	mode=$1 &&
	shift &&
	rm -f filter.log special.log "$@" &&
	git -c checkout.streamFilterOutput=$mode checkout -- "$@"
}

test_expect_success 'setup' '
	git config filter.protocol.process \
		"test-tool rot13-filter --log=filter.log clean smudge" &&
	# The failure cases get a filter process of their own, so that
	# an "abort" does not affect the other tests.
	git config filter.special.process \
		"test-tool rot13-filter --log=special.log clean smudge" &&
	cat >.gitattributes <<-\EOF &&
	*.r filter=protocol
	*-content.r filter=special
	die-mid-stream.r filter=special
	later.r filter=special
	EOF
	git add .gitattributes &&

	for size in $SIZES
	do
		gen_text $size raw-$size &&
		"$TEST_ROOT/rot13.sh" <raw-$size >expect-$size &&
		add_raw size-$size.r raw-$size || return 1
	done &&

	echo "executable content" >raw-exec &&
	"$TEST_ROOT/rot13.sh" <raw-exec >expect-exec &&
	add_raw exec.r raw-exec 100755 &&

	for f in error-after-content.r abort-after-content.r die-mid-stream.r \
		 later.r
	do
		# Big enough that die-mid-stream.r sends a partial file.
		gen_text 100000 raw-$f &&
		add_raw $f raw-$f || return 1
	done &&

	git commit -q -m initial
'

for mode in false true
do
	test_expect_success "content is identical for all sizes (stream=$mode)" '
		checkout_with $mode size-*.r &&
		for size in $SIZES
		do
			test_cmp_bin expect-$size size-$size.r || return 1
		done
	'

	test_expect_success "stat info is correct after checkout (stream=$mode)" '
		checkout_with $mode size-*.r &&
		# Avoid racy-git re-hashing, which would run the clean
		# filter regardless of how the files were written.
		test-tool chmtime =+10 .git/index &&
		rm -f filter.log &&
		git status --porcelain -- size-*.r >actual &&
		test_must_be_empty actual &&
		git diff --quiet -- size-*.r &&
		! grep "IN: clean" filter.log
	'

	test_expect_success POSIXPERM "executable bit is kept (stream=$mode)" '
		checkout_with $mode exec.r &&
		test_cmp expect-exec exec.r &&
		test -x exec.r
	'

	for f in error-after-content abort-after-content die-mid-stream
	do
		test_expect_success "$f: optional filter falls back to blob (stream=$mode)" '
			checkout_with $mode $f.r later.r &&
			test_cmp_bin raw-$f.r $f.r &&
			"$TEST_ROOT/rot13.sh" <raw-later.r >expect &&
			if test $f = abort-after-content
			then
				# The filter must not be asked again.
				! grep "IN: smudge later.r" special.log &&
				test_cmp_bin raw-later.r later.r
			else
				test_cmp_bin expect later.r
			fi
		'

		test_expect_success "$f: required filter leaves no file (stream=$mode)" '
			rm -f $f.r &&
			test_must_fail git -c filter.special.required=true \
				-c checkout.streamFilterOutput=$mode \
				checkout -- $f.r 2>err &&
			test_grep "smudge filter special failed" err &&
			test_path_is_missing $f.r
		'
	done

	test_expect_success "checkout-index --temp (stream=$mode)" '
		git -c checkout.streamFilterOutput=$mode \
			checkout-index --temp size-3000000.r size-0.r >out &&
		big=$(grep "size-3000000.r\$" out | cut -f1) &&
		empty=$(grep "size-0.r\$" out | cut -f1) &&
		test_cmp_bin expect-3000000 "$big" &&
		test_must_be_empty "$empty" &&
		rm -f "$big" "$empty"
	'

	test_expect_success "delayed checkout (stream=$mode)" '
		test_when_finished "rm -rf delayed" &&
		git clone -q --no-checkout . delayed &&
		(
			cd delayed &&
			git config filter.protocol.process \
				"test-tool rot13-filter --always-delay --log=filter.log clean smudge delay" &&
			git -c checkout.streamFilterOutput=$mode checkout -q main &&
			grep "\[DELAYED\]" filter.log &&
			for size in $SIZES
			do
				test_cmp_bin ../expect-$size size-$size.r || return 1
			done &&
			git status --porcelain -- size-*.r >actual &&
			test_must_be_empty actual
		)
	'

	test_expect_success "commands that write the working tree (stream=$mode)" '
		test_when_finished "rm -rf cmds" &&
		git init -q cmds &&
		(
			cd cmds &&
			git config filter.protocol.process \
				"test-tool rot13-filter --log=filter.log clean smudge" &&
			git config checkout.streamFilterOutput $mode &&
			echo "*.r filter=protocol" >.gitattributes &&
			git add .gitattributes &&
			add_raw big.r ../raw-3000000 &&
			add_raw small.r ../raw-1 &&
			git commit -q -m initial &&

			rm -f big.r small.r &&
			git reset -q --hard &&
			test_cmp_bin ../expect-3000000 big.r &&

			rm big.r &&
			git restore big.r &&
			test_cmp_bin ../expect-3000000 big.r &&

			git switch -q -c other &&
			echo change >>big.r &&
			git commit -q -am change &&
			cp big.r ../expect-changed &&
			git switch -q main &&
			test_cmp_bin ../expect-3000000 big.r &&
			git switch -q other &&
			test_cmp_bin ../expect-changed big.r &&
			git switch -q main &&

			echo change >>big.r &&
			git stash -q &&
			test_cmp_bin ../expect-3000000 big.r &&
			git stash apply -q &&
			test_cmp_bin ../expect-changed big.r &&
			git reset -q --hard &&

			git merge -q --no-edit other &&
			test_cmp_bin ../expect-changed big.r &&
			git status --porcelain -uno >actual &&
			test_must_be_empty actual
		)
	'

	test_expect_success "clone (stream=$mode)" '
		test_when_finished "rm -rf clone" &&
		git -c filter.protocol.process="test-tool rot13-filter --log=../filter.log clean smudge" \
			-c filter.special.process="test-tool rot13-filter --log=../special.log clean smudge" \
			-c checkout.streamFilterOutput=$mode clone -q . clone &&
		for size in $SIZES
		do
			test_cmp_bin expect-$size clone/size-$size.r || return 1
		done
	'
done

# Print the peak resident set size, in KiB, of running the given command.
max_rss_kb () {
	case "$(uname -s)" in
	Darwin)
		/usr/bin/time -l "$@" 2>time.out >/dev/null &&
		awk "/maximum resident set size/ { print int(\$1 / 1024) }" time.out
		;;
	*)
		/usr/bin/time -v "$@" 2>time.out >/dev/null &&
		awk -F: "/Maximum resident set size/ { print \$2 + 0 }" time.out
		;;
	esac
}

test_lazy_prereq TIME_RSS '
	case "$(uname -s)" in
	Darwin) /usr/bin/time -l true ;;
	*) /usr/bin/time -v true ;;
	esac
'

test_expect_success TIME_RSS 'setup memory test' '
	git init mem &&
	(
		cd mem &&
		git config filter.expand.process \
			"test-tool rot13-filter --log=filter.log clean smudge" &&
		echo "*.r filter=expand" >.gitattributes &&
		echo pointer >p &&
		add_raw expand-$((100 * 1024 * 1024)).r p &&
		add_raw expand-$((2 * 1024 * 1024 * 1024)).r p &&
		git add .gitattributes &&
		git commit -q -m mem
	)
'

# Peak memory must not depend on the size of the smudged file when
# streaming, and must when not, or the test would not prove anything.
check_rss () {
	size=$1 bound_kb=$2 &&
	(
		cd mem &&
		for mode in true false
		do
			rm -f expand-$size.r &&
			kb=$(max_rss_kb git -c checkout.streamFilterOutput=$mode \
				checkout -- expand-$size.r) &&
			test $(wc -c <expand-$size.r) = $size &&
			echo "stream=$mode: $kb KiB" &&
			if test $mode = true
			then
				test $kb -lt $bound_kb
			else
				test $kb -gt $bound_kb
			fi || return 1
		done
	)
}

test_expect_success TIME_RSS 'peak memory is bounded when streaming' '
	check_rss $((100 * 1024 * 1024)) $((50 * 1024))
'

test_expect_success TIME_RSS,EXPENSIVE 'peak memory is bounded for multi-GB output' '
	check_rss $((2 * 1024 * 1024 * 1024)) $((64 * 1024))
'

test_done
