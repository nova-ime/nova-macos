# nova-ui 的独立构建和单元测试：make test
# 只需要 C++17 编译器，不依赖 librime。nova_ui_rime（src/rime_glue.cc）要 librime 头文件，单独用
# `make rime-syntax` 检查（RIME_INC 指向 librime/src）。
CXX ?= c++
# -ffp-contract=off：浮点结果要和原来的 Swift 实现完全一致，见 src/layout.cc。
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -ffp-contract=off
RIME_INC ?= ../librime/src
BUILD ?= build

CORE := src/model.cc src/layout.cc src/theme.cc

$(BUILD)/libnova_ui.a: $(CORE)
	@mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) -c src/model.cc -o $(BUILD)/model.o
	$(CXX) $(CXXFLAGS) -c src/layout.cc -o $(BUILD)/layout.o
	$(CXX) $(CXXFLAGS) -c src/theme.cc -o $(BUILD)/theme.o
	ar rcs $@ $(BUILD)/model.o $(BUILD)/layout.o $(BUILD)/theme.o

$(BUILD)/test_nova_ui: tests/test_nova_ui.cc $(BUILD)/libnova_ui.a include/nova_ui.h
	$(CXX) $(CXXFLAGS) tests/test_nova_ui.cc $(BUILD)/libnova_ui.a -o $@

.PHONY: test rime-syntax clean
test: $(BUILD)/test_nova_ui
	$(BUILD)/test_nova_ui

rime-syntax:
	$(CXX) $(CXXFLAGS) -I$(RIME_INC) -fsyntax-only src/rime_glue.cc
	$(CXX) $(CXXFLAGS) -I$(RIME_INC) -DNOVA_UI_RIME_STDBOOL -fsyntax-only src/rime_glue.cc

clean:
	rm -rf $(BUILD)
