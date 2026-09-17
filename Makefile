# Сборка документации: make html (результат в _build/html), make clean
SPHINXOPTS    ?=
SPHINXBUILD   ?= sphinx-build
SOURCEDIR     = .
BUILDDIR      = _build

.PHONY: help html clean

help:
	@echo "make html   - собрать документацию в $(BUILDDIR)/html"
	@echo "make clean  - удалить $(BUILDDIR)"

html:
	$(SPHINXBUILD) -b html $(SPHINXOPTS) -d $(BUILDDIR)/doctrees "$(SOURCEDIR)" "$(BUILDDIR)/html"
	@touch "$(BUILDDIR)/html/.nojekyll"
	@echo "Готово: $(BUILDDIR)/html/index.html (открывать через toc.html)"

clean:
	rm -rf "$(BUILDDIR)"
