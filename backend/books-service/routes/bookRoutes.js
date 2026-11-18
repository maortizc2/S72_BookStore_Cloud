import express from "express";
import {
  getBookByIsbn,
  getBooks,
  reserveBookStock,
} from "../controllers/bookController.js";

const router = express.Router();

router.get("/", getBooks);
router.post("/stock/reserve", reserveBookStock);
router.get("/:isbn", getBookByIsbn);

export default router;
