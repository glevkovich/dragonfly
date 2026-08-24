// Copyright 2026, DragonflyDB authors.  All rights reserved.
// See LICENSE for licensing terms.

#include "facade/proactor_read_buffer.h"

#include <gmock/gmock.h>

#include "base/gtest.h"
#include "util/fibers/fibers.h"

namespace facade {
namespace {

TEST(ProactorReadBufferTest, RejectsSecondBorrowUntilFirstIsReleased) {
  ProactorReadBuffer read_buffer;
  read_buffer.Init(128);

  auto first_borrow = read_buffer.TryBorrow(1);
  ASSERT_TRUE(first_borrow);
  EXPECT_TRUE(read_buffer.in_use());
  EXPECT_EQ(read_buffer.OwnerConnId(), 1u);
  EXPECT_FALSE(read_buffer.TryBorrow(2));

  first_borrow.reset();
  EXPECT_FALSE(read_buffer.in_use());
  EXPECT_TRUE(read_buffer.TryBorrow(2));
}

TEST(ProactorReadBufferDeathTest, RejectsNonEmptyBufferOnRelease) {
  EXPECT_DEATH(
      {
        ProactorReadBuffer read_buffer;
        read_buffer.Init(128);
        auto borrow = read_buffer.TryBorrow(1);
        borrow->buf().WriteAndCommit("x", 1);
      },
      "");
}

TEST(ProactorReadBufferDeathTest, RejectsFiberSwitchDuringBorrow) {
  EXPECT_DEATH(
      {
        ProactorReadBuffer read_buffer;
        read_buffer.Init(128);
        auto borrow = read_buffer.TryBorrow(1);
        util::fb2::Fiber other("switch_epoch", [] {});
        other.Join();
      },
      "");
}

}  // namespace
}  // namespace facade
