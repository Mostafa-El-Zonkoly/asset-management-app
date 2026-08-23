# frozen_string_literal: true

module Settings
  class CategoriesController < ApplicationController
    before_action :set_category, only: %i[edit update destroy]

    def index
      @categories = Category.includes(:category_type).order(:name)
    end

    def new
      @category = Category.new
      @category_types = CategoryType.active.order(:position)
    end

    def edit
      @category_types = CategoryType.active.order(:position)
    end

    def create
      @category = Category.new(category_params)
      if @category.save
        redirect_to settings_categories_path, notice: "Category created."
      else
        @category_types = CategoryType.active.order(:position)
        render :new, status: :unprocessable_entity
      end
    end

    def update
      if @category.update(category_params)
        redirect_to settings_categories_path, notice: "Category updated."
      else
        @category_types = CategoryType.active.order(:position)
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @category.destroy!
      redirect_to settings_categories_path, notice: "Category removed."
    end

    private

    def set_category
      @category = Category.find(params[:id])
    end

    def category_params
      params.require(:category).permit(:name, :category_type_id, :description)
    end
  end
end
